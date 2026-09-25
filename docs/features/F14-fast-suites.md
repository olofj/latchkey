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

**2026-09-25, L1 at 38 tests: where 609 s goes, and whether F14 is worth it.**
From run `offline-logs/20260925-025305` (xcresult activity timelines, file
birth times). Of 609 s, **587 s is inside test methods**; the rest is setup
(~7 s), a no-op `--build` (3 s) and two `xcodebuild` spin-ups (~8 s and ~5 s,
the second being R1's sign-in pass).

*The floor.* A cold launch is **5.0 s** to a usable native screen (3.3 s of
XCUITest automation setup and spawn before its idle wait, ~1.7 s to idle) and
**~6.0 s** when the page loads; a terminate is **1.06 s**. L1 has **46 cold
launches** (plus three re-activations after Safari), so launch + terminate is
**319 s, 54 % of the test time**. The 2026-09-24 estimate of ~165 s had the
per-launch cost right and the count wrong: launches went from 22 to 46 as the
suite went from 17 tests to 38. Launch spans are capped at 6.0 s in this
accounting, so harness polling that runs before a test's first UI query is
counted as variable, not launch.

| # | Test | 609 s run | launches | fixed | variable | after |
|---|---|---|---|---|---|---|
| 1 | `testStalledLoadShowsTheConnectingStateForItsWholeDuration` | 38.2 | 1 | 7.1 | 31.1 | 38.1 |
| 2 | `testANodeThatCannotStartShowsAScreenInsteadOfDying` | 36.0 | 1 | 6.1 | 29.9 | 36.0 |
| 3 | `testTheAppBarRetractsOnADeliberateScrollAndComesBack` | 29.4 | 2 | 14.1 | 15.4 | 29.9 |
| 4 | `testTypingInThePageKeepsItOnScreen` | 28.9 | 2 | 14.0 | 14.9 | 28.7 |
| 5 | `testInsetProbesReportWhatThePageIsTold` | 27.8 | 3 | 21.2 | 6.6 | 27.3 |
| 6 | `testStatusNamesTheCommitTheAppWasBuiltFrom` | 26.2 | 1 | 7.0 | 19.1 | 26.2 |
| 7 | `testStrictModeBlocksTheAllowlistedCDNs` | 25.7 | 1 | 7.0 | 18.7 | 25.3 |
| 8 | `testNothingOfOursSitsOnThePageAndSettingsIsReachable` | 24.8 | 1 | 7.0 | 17.8 | 24.8 |
| 9 | `testBlockedImageShowsAMarkerThatOpensSafari` | 21.7 | 1 | 8.3 | 13.4 | 16.9 |
| 10 | `testStartingANewNodeMovesTheOldStateAsideAndKeepsIt` | 17.9 | 2 | 12.8 | 5.1 | 18.1 |
| 11 | `testLoggingSetupFailureStopsTheNodeRatherThanStartingItBlind` | 17.4 | 1 | 7.1 | 10.3 | 17.4 |
| 12 | `testTheErrorPageOffersRetryAndAnotherGateway` | 17.2 | 2 | 14.2 | 3.0 | 17.6 |
| 13 | `testAnUnwritableStateDirectoryIsSurvived` | 16.3 | 2 | 13.0 | 3.3 | 16.5 |
| 14 | `testTryNowRestartsTheNodeImmediately` | 14.5 | 1 | 6.0 | 8.5 | 14.5 |
| 15 | `testWindowOpenToAnotherOriginStillOpensSafari` | 14.5 | 1 | 8.2 | 6.3 | 14.5 |
| 16 | `testAnAllowlistedCDNIsFetchedAndItsLookalikesAreNot` | 13.2 | 1 | 7.1 | 6.1 | 13.0 |
| 17 | `testAReturningUserIsNotReintroduced` | 13.2 | 2 | 13.0 | 0.2 | 13.3 |
| 18 | `testThePageCannotWidenTheAllowlist` | 13.0 | 1 | 7.0 | 5.9 | 0.1 |
| 19 | `testWithoutTheRuleListTheAwayOriginIsReached` | 12.9 | 1 | 7.1 | 5.8 | 12.9 |
| 20 | `testTheFontHostsStayBlockedWhileTheCDNsAreAllowed` | 12.9 | 1 | 7.1 | 5.8 | 0.1 |
| 21 | `testOffOriginLoadsNeverReachTheAwayOrigin` | 12.8 | 1 | 7.1 | 5.8 | 0.1 |
| 22 | `testRedirectToAnotherOriginLeavesTheAppAndKeepsTheDashboard` | 12.8 | 1 | 8.1 | 4.6 | 12.7 |
| 23 | `testFailedRuleCompileLoadsNothing` | 12.0 | 1 | 7.2 | 4.9 | 11.8 |
| 24 | `testSignInTokenIsStrippedFromTheAddress` | 11.6 | 1 | 7.1 | 4.5 | 12.2 |
| 25 | `testTheNodeStartRetryIsVisibleAndSucceeds` | 10.3 | 1 | 6.1 | 4.3 | 10.5 |
| 26 | `testDashboardLoadsThroughTheProxy` | 9.9 | 1 | 7.1 | 2.8 | 9.0 |
| 27 | `testAGatewayAnswering502ShowsTheErrorPageInsteadOfABlankScreen` | 9.6 | 1 | 7.0 | 2.6 | 9.7 |
| 28 | `testAFastLoadDoesNotLeaveTheConnectingStateOnScreen` | 9.2 | 1 | 7.1 | 2.1 | 9.8 |
| 29 | `testProxyGoneWithoutRelayFailsWithoutDirectFallback` | 8.9 | 1 | 7.1 | 1.8 | 8.4 |
| 30 | `testProxyGoneFailsWithoutDirectFallback` | 8.6 | 1 | 7.0 | 1.6 | 9.0 |
| 31 | `testUnreachableGatewayShowsTheErrorPage` | 8.4 | 1 | 7.1 | 1.3 | 7.9 |
| 32 | `testTheGatewaysOwnMachineryStillWorks` | 8.1 | 1 | 7.0 | 1.1 | 8.0 |
| 33 | `testCertificateNameMismatchShowsTheErrorPage` | 8.0 | 1 | 7.1 | 0.9 | 8.2 |
| 34 | `testBlackholedProxyFailsWithoutDirectFallback` | 7.9 | 1 | 7.1 | 0.8 | 8.0 |
| 35 | `testNonTailnetOriginLoadsDirectAndNeverTouchesTheProxy` | 7.8 | 1 | 7.1 | 0.7 | 7.9 |
| 36 | `testTheSignInButtonSurvivesItsOwnCopy` | 6.6 | 1 | 6.2 | 0.3 | 6.5 |
| 37 | `testAFirstLaunchExplainsItself` | 6.3 | 1 | 6.1 | 0.2 | 6.5 |
| 38 | `testTheIntroductionNamesThePostLoginSteps` | 6.2 | 1 | 6.0 | 0.2 | 6.3 |
| | **sum** | **586.7** | **46** | **319.0** | **267.7** | **543.7** |

After the change, the 268 s of variable time splits as follows:

- ~77 s: pinned app timings, the one test per constant: the stalled load (F4),
  the node-start backoff 1+2+4+8+16 s (F8), and Try-now waiting out the real
  backoff to attempt 4.
- ~51 s: the F6 page's own schedule (synthetic click at +4 s, then a 1 s
  settle) and its absence windows.
- ~73 s: gestures, rotation, the keyboard and layout settling (F9/F12/F13/
  F15). A slow swipe plus XCUITest's idle wait is 2.6–3 s, and Status alone
  swipes five times.
- ~19 s: F8's node-start absence windows.
- ~27 s: everything else.

*Landed* (`l1: share one settled F6 run…`): four F6 tests launched
identically, waited for the same settle and then only read the instruments.
They now share one snapshot of that run: report, counters and journal. Each
still asserts its own claim under its own name. The run is cached only if it
settled, and a test run alone takes its own launch (checked:
`testThePageCannotWidenTheAllowlist` alone passes in 16.4 s). One
`test-offline.sh --build`: **609 s → 569 s**, 38 names identical (diffed),
all passing.

*Rejected after inspection:*

- **Firing the F6 page's synthetic click as soon as its markers exist.** The
  fixed +4 s is also the negatives' observation window ("every off-origin
  load it makes has been asked for by then"). The positive control, with no
  rule list and so no markers, would have kept the full window.
- **Faster inset/shell report cadence.** "Several reports in" is the layout
  settle itself.
- **Shortening the absence sleeps** (logging refusal +10 s/+5 s, redirect 3 s,
  blocked image 3 s, rule compile 2+2 s). Each is the evidence that nothing
  happened.
- **Folding the sign-in pass into the suite pass** (~5 s). R1 needs it last,
  and XCTest orders by name.
- **Skipping terminates.** The next `launch()` pays the same cost.

*What is left, and what F14 would buy.* After this, 43 launches are ~297 s of
launch and terminate, plus ~26 s outside the tests: **~320 s serial floor with
zero variable time**. Add the ~77 s of pinned timings and L1 cannot go below
~400 s serially without fewer launches, which is §3's ruled-out merging. The
240 s budget is therefore unreachable serially, and §4.2's scaling has little
left to act on in L1: the only long timers are the pinned ones. The remaining
lever is §3's parallel harness: per-simulator ports plumbed into the launch
arguments and the certificate SANs, plus per-instance fake-dashboard and proxy
control state. The ideal wall time is ~26 s + max(38 s, 544 s ÷ N):
~160 s at N = 4 and ~95 s at N = 8, on this 20-core M1 Ultra. The ideal does
not include simulator contention, which is unmeasured. The longest test
(38 s) bounds it below at ~65 s. §2's "L1 under 90 s" needs N ≥ 8, and even
then only if contention is small.

**2026-09-25, simulator contention measured: F14 reaches 240 s at N = 4.**
The projection above assumed simulators do not slow each other. This measures
that, with `scripts/bench-sim-contention.py` (run `simbench-logs/20260925-043549`,
all rounds passing). It times L1's own fixed cost: `testAFirstLaunchExplainsItself`
(an XCUITest launch into the gate, four checks, a terminate). It runs with
`-test-iterations 10` on N dedicated iPhone 17 simulators at once, one
`xcodebuild test-without-building` each. The gate needs no node and no
certificates. One stub answering 200 on the two control ports satisfies every
simulator's `setUp`. Confounders kept out: all 12 simulators were booted and
settled before anything was timed, and a warm-up round was discarded. Iteration
1 of each run (the cold launch after install) is dropped, so install is in no
number. Only iterations wholly inside the window where all N ran are counted. A
closing N = 1 round came in at 0.97× the first, so there was no drift. No
thermal warning was recorded in any round. N = 1 ran with the other 11
simulators booted and idle; a two-simulator smoke run gave the same 6.7 s.

| N | kept | test median s (p25–p75, max) | launch to usable s | × N=1 | launches/s, all sims | speedup | per-sim efficiency | CPU busy median/max % | swap |
|---|---|---|---|---|---|---|---|---|---|
| 1 | 9 | 6.66 (6.53–6.92, 7.23) | 5.36 | 1.00 | 0.142 | 1.00 | 1.00 | 37/60 | 0 |
| 2 | 17 | 6.78 (6.63–6.85, 7.02) | 5.41 | 1.02 | 0.275 | 1.94 | 0.97 | 42/84 | 0 |
| 4 | 33 | 7.08 (7.02–7.19, 9.40) | 5.68 | 1.06 | 0.526 | 3.71 | 0.93 | 56/98 | 0 |
| 6 | 49 | 7.26 (7.17–7.40, 8.33) | 5.73 | 1.09 | 0.738 | 5.20 | 0.87 | 71/100 | 0 |
| 8 | 65 | 7.61 (7.52–7.77, 8.57) | 6.03 | 1.14 | 0.945 | 6.66 | 0.83 | 89/100 | 0 |
| 12 | 91 | 7.87 (7.72–8.36, 19.15) | 6.21 | 1.18 | 1.207 | 8.50 | 0.71 | 100/100 | 153 MB |

"Launch to usable" runs from XCUITest's `Open` to the first UI query. Terminate
is 1.05–1.08 s at every N. Speedup is measured throughput, which is lower than
N ÷ (× N=1) because it also counts stragglers.

- **Contention is real but modest up to 8.** A launch costs 6 % more at N = 4
  and 14 % more at N = 8. Adding simulators stops paying at **N ≈ 8**. Each one
  added from 2 to 8 returns 0.7–0.9 of a simulator. From 8 to 12 each returns
  0.46. At N = 8 the CPU is 89 % busy at the median. At N = 12 it is pinned at
  100 %, swapping starts, and a straggler takes 19 s.
- **Memory is not the limit.** Twelve booted simulators took
  `kern.memorystatus_level` from 87 to ~50 (about 1.8 GB each of 64 GB), and
  nothing swapped below N = 12.
- **Booting is the expensive part, and it must stay out of the run.** One
  first boot takes 20–23 s. Twelve at once took 70–343 s each, then 8 min
  before the host dropped under 25 % busy. F14's simulators must stay booted
  between runs, or be booted one at a time, never all at once inside L1.
- **Per-shard `xcodebuild` spin-up,** including installing the app and runner,
  grows from 6.1 s at N = 1 to 8.7 s (max) at N = 8: about +3 s of wall time.

*Corrected L1 projection* (replacing ~160 s / ~95 s). The model is 26 s outside
the tests plus the longest-first packing of the 38 per-test times ("after"
column above) onto N simulators. The low figure slows only each test's
launch/terminate share, by × N=1. The high figure slows whole tests by the
throughput loss. The high figure is pessimistic: most variable time is timers
and sleeps, which do not contend.

| N | no contention | measured contention |
|---|---|---|
| 2 | 300 s | 303–309 s |
| 4 | 164 s | **168–175 s** |
| 6 | 118 s | 123–133 s |
| 8 | 97 s | **103–111 s** |
| 12 | 73 s | 79–93 s (CPU-saturated, swapping) |

Add ~3 s for the slower spin-up at N ≥ 4. **F14 can reach the 240 s budget: N
= 4 gives ~170–180 s, with room for the suite to grow.** N = 3 interpolates to
~215 s, which leaves too little margin. §2's "under 90 s" is not reachable on
this host. It would take N = 12, which saturates the CPU and swaps, and the
38 s longest test × 1.18 bounds it at ~71 s anyway. N = 8 (~105–115 s) is
where the curve stops paying.

Not covered by this measurement:

- The gate has no WebView. Most L1 launches also start WebKit's three
  processes (§9: ~6.0 s to idle, against 5.0 s), so page launches may contend
  somewhat more than measured. The high column is meant to absorb that.
- It says nothing about the per-instance harness state F14 has to build.
- The sandbox hid the host's process list, so nothing other than the idle 8 %
  baseline and CPU samples before each round could be attributed. The 1-minute
  load average (500–1000) counts simulator threads and is not comparable to the
  20 cores.
