# F14 — The suites are too slow to iterate against

| | |
|---|---|
| **Status** | spec |
| **Requested** | 2026-09-24, by Olof: "The tests run way too slow for this project to be productive. So much waiting for results needs to be optimized away as much as possible." |
| **Revision** | none |
| **Touches** | `scripts/test-*.sh`, `app/UITests/`, the app's test hooks, `testing/harness/` |

## 1. Why

Measured today:

| Suite | Time | Tests |
|---|---|---|
| L1 (`test-offline.sh`) | **254 s** (budget 240) | 15 |
| M4 session (`test-session.sh`) | **482 s** | 16 |
| M5 discovery | 233 s | — |
| M6 lifecycle | 155 s | — |
| full tier (`test-all.sh --full`) | ~17 min | — |

That is ~17 s per L1 test and 15–55 s per session test. The cost is not machine
time, it is the **iteration loop**: a one-line change waits minutes for an
answer, so it gets made without one. Two of the last three bugs reached Olof's
phone rather than a suite, and F10 has already established that the suites were
structurally unable to see one of them. A suite you avoid running is a suite that
does not protect you.

## 2. What the owner sees

A change to browser code gets a verdict in a time he will actually wait for.
Target, to be revised once §4.1 has the data: **L1 under 90 s**, the session
suite under 180 s, with **no test removed and no assertion weakened**.

## 3. Non-goals

- **Not deleting or merging tests to make a number go down.** The obvious wrong
  answer. §7 makes "the same tests still run and still pass" a hard criterion,
  measured by name and count, not by wall clock alone.
- **Not weakening what a test proves.** A test that no longer waits for the real
  timeout must still prove the timeout behaviour — see §4.2.
- **Not parallelising across the shared harness.** The fake dashboard and stub
  proxy bind fixed ports and hold global control state (`/__mode`,
  `/__slots`, mode resets in `setUp`); two tests changing modes at once would
  race invisibly. Ports are `?=` overridable but nothing plumbs them through to
  the app's launch arguments or the certificate SANs. This is a real project, not
  a flag, and it is out of scope here — but write down what it would take, so the
  next person does not rediscover it.

## 4. Design

### 4.1 Measure first — the whole design depends on it

Nothing here is to be optimised on a hunch. Produce a breakdown of where L1's
254 s and the session suite's 482 s actually go:

- **per-test app launch** — XCUITest relaunches between test methods; multiply
  the launch cost by the test count and see how much of the total it is;
- **deliberate waiting** — time spent in `sleep`/polling for app timers to fire;
- **harness setup/teardown** — certs, ports, `make check`, simulator boot;
- **build** — only when `--build` is passed;
- **the rest**.

`xcodebuild` already prints per-test durations, and the suites log their own
phases. Report the table before changing anything.

### 4.2 The most promising lever: the app's own deliberate delays

The app is full of timings a test must *wait out*, because they are the
behaviour: `PageStateView.showDelay` 300 ms, `connectingHintDelay` 8 s,
`holdingHintDelay` 15 s; the gate's 15 s stall hint (F4 §3.6); discovery's 4 s
per-probe timeout and 12 s sweep deadline (R39); the session manager's timeouts.
A suite asserting the 15 s hint spends 15 s doing nothing.

Make them overridable at launch, through the existing test-hook channel
(`LATCHKEY_TEST_HOOKS`, alongside `-UITestHomePage`, `-UITestKeepWebData`).

**The catch, which must not be fudged:** a test running on scaled timings no
longer proves the shipped timings. So exactly one test per constant keeps the
real value and pins it — the expensive one stays, once — and every other test
that merely needs to *get past* that delay runs scaled. State this in each
test's name or comment so the distinction survives.

Do not scale time globally with a single multiplier if the constants interact
(discovery's probe timeout and sweep deadline do: 4 s × 12 concurrency ÷ 12 s
deadline is what sets the truncation boundary, and a global scale would move a
boundary some tests sit exactly on).

### 4.3 Per-test launch cost

If §4.1 shows launches dominate, the levers are: fewer launches (share a launch
across assertions that do not need isolation — but see §3, this must not become
test-merging by stealth), or a cheaper launch (what does the app do before it is
usable? the tsnet node start, the workspace load, the first navigation).

### 4.4 Cheap wins to check while measuring

- Does `--build` rebuild when nothing changed?
- Is the simulator booted once per suite or once per test?
- Do the harnesses regenerate certificates every run? (`certs present and valid`
  suggests not, but confirm.)
- Does `test-all.sh`'s quick tier still skip what it claims to skip?
- Is any suite paying for a timeout that only ever fires on failure?

**Invariants this must not break** (see `app/AGENTS.md`): every suite still fails
unless every test in it passed; no change to the split tunnel, `allowFailover`,
ATS or D1; no vendored-tree change.

## 5. State and migration

Nothing persisted. New launch arguments are test-only and inert in a Release
build; confirm they are compiled out with `LATCHKEY_TEST_HOOKS`.

## 6. End-to-end tests

The deliverable is a speed-up, so the test is a comparison, and its integrity
matters more than its result:

| Test | Asserts | Shown to fail by |
|---|---|---|
| Coverage is unchanged | The set of test NAMES that ran, before and after, is identical, and all pass | Deleting or renaming one test: the comparison names it |
| The timing constants are still pinned | For each scaled constant, exactly one test still exercises the shipped value | Scaling the pinning test too: the check reports the constant nobody proves any more |
| It is actually faster | L1 and the session suite, same machine, same `--build` state, before and after | It is the measurement |

## 7. Acceptance criteria

1. A table of where the time went, before any change — §4.1.
2. Same test names, same count, all passing — §6 row 1. **A run that is faster
   because it does less is a failure of this feature, not a success.**
3. Each scaled constant has exactly one test still proving the shipped value.
4. L1 comfortably inside its 240 s budget, with the new figure recorded and the
   budget re-set to something meaningful rather than something it just squeaks
   under.

## 8. Open questions and owner actions

- **How much of the 17 s per L1 test is launch?** Decides whether §4.2 or §4.3 is
  the main lever. §4.1 answers it; do not guess.
- The parallel-harness project (§3) is deliberately deferred. If §4.1 shows the
  remaining time is dominated by things parallelism would fix, say so and it
  becomes its own spec.
- No owner action.

## 9. Log

Opened 2026-09-24. L1 was 254 s against a 240 s budget that day, having grown
from 248 s when F12 added a test, which is the sort of drift this spec exists to
stop.

**2026-09-24, L1 pass.** Asked for L1 under 120 s. Not reached: **321 s → 272 s**,
17 tests before and after, names identical (diffed), all passing, one
`test-offline.sh --build` each. (The 257 s quoted with the request was the
15-test run; F15's two tests had since taken it to 321 s.)

Where L1's time goes, from the xcresult activity timelines and the unified log:

- **Launches are the floor.** 22 launches (three tests relaunch) at 6–9 s to
  idle, plus ~1.1 s per terminate: ~165 s. Of each launch, ~1 s is XCUITest's
  automation setup and **1.6 s passes between spawn and the first dyld
  initializer** — simulator launch plumbing, before any code of ours runs
  (`DYLD_PRINT_INITIALIZERS`); the rest is WebKit's three processes starting
  and the first load.
- **The app's own timers are not an L1 cost.** `showDelay` and
  `connectingHintDelay` are waited out only by the two tests that pin them
  (`testAFastLoad…` asserts a loopback load stays under the 300 ms show delay;
  `testStalledLoad…` checkpoints the 8 s hint and needs a stall past the 20 s
  startup-retry window). `holdingHintDelay`, the gate's stall hint and
  discovery's probe/sweep timings are not reached by any L1 test. So nothing
  was scaled and no override was added: in L1 there is no test that merely
  gets past a delay. They matter to M4/M5, not measured here.
- **XCTest's own polling was the waste.** `waitForExistence` first looks ~1 s
  after it starts (measured 1.07 s for an element already on screen), and L1
  had ~40 of them; `reveal` paid a 2 s wait before every swipe for rows that
  only appear by scrolling; `statusRow`'s predicate expectation the same 1 s.
  Now `appears(within:)`/`disappears(within:)` in `UITestSupport.swift` poll
  every 100 ms with the same timeouts, and `reveal` waits 0.5 s per step. The
  one deliberate absence window (the redirect test's 3 s) is unchanged.
- Checked and not a cost: the simulator boots once per run; certs are not
  regenerated (0.04 s); `make check` 1.5 s; `harness-up` 0.7 s; the second
  `xcodebuild` pass for the sign-in test ~9 s, which R1's ordering needs.

| Test | before s | after s |
|---|---|---|
| `testAFastLoadDoesNotLeaveTheConnectingStateOnScreen` | 9.0 | 9.0 |
| `testAGatewayAnswering502ShowsTheErrorPageInsteadOfABlankScreen` | 10.4 | 9.4 |
| `testBlackholedProxyFailsWithoutDirectFallback` | 8.0 | 7.7 |
| `testCertificateNameMismatchShowsTheErrorPage` | 9.3 | 7.7 |
| `testDashboardLoadsThroughTheProxy` | 9.1 | 9.0 |
| `testInsetProbesReportWhatThePageIsTold` | 36.2 | 30.4 |
| `testNonTailnetOriginLoadsDirectAndNeverTouchesTheProxy` | 7.8 | 8.1 |
| `testNothingOfOursSitsOnThePageAndSettingsIsReachable` | 27.6 | 17.6 |
| `testProxyGoneFailsWithoutDirectFallback` | 11.0 | 8.2 |
| `testProxyGoneWithoutRelayFailsWithoutDirectFallback` | 11.0 | 8.4 |
| `testRedirectToAnotherOriginLeavesTheAppAndKeepsTheDashboard` | 13.6 | 13.1 |
| `testSignInTokenIsStrippedFromTheAddress` | 10.7 | 11.8 |
| `testStalledLoadShowsTheConnectingStateForItsWholeDuration` | 38.6 | 38.0 |
| `testStatusNamesTheCommitTheAppWasBuiltFrom` | 31.0 | 19.2 |
| `testTheAppBarRetractsOnADeliberateScrollAndComesBack` | 32.3 | 27.1 |
| `testTheErrorPageOffersRetryAndAnotherGateway` | 18.7 | 17.2 |
| `testUnreachableGatewayShowsTheErrorPage` | 8.4 | 7.9 |
| **sum of tests** | **293** | **250** |

What 120 s would take: with ~165 s of launch alone serial, only running tests
concurrently (§3's parallel harness: per-simulator ports plumbed into the launch
arguments and the certificate SANs) or fewer launches (the inset probe's three,
the app bar's two) gets there, and the second is the test-merging §3 rules out
unless the owner decides otherwise. The 240 s budget in `test-offline.sh` is
left as it was; 272 s is still over it.
