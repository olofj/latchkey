# F21 — A cold launch arrives at the dashboard without flashing through screens

| | |
|---|---|
| **Status** | spec; nothing built. The first task is measurement (§4.0), because the screen count in issue #4 is inferred from the code, not observed |
| **Requested** | 2026-09-26, by Olof (issue #4): "When the app starts cold there's a lot of flashing on the screen on the way in to the actual default dashboard, likely something like logins and connection screens but they flash fast and I can't tell. It's visually jarring." Then: "Maybe consider a splash screen, worst case?" |
| **Revision** | likely none. Nothing documented promises these screens appear; F4 and F8 promise they appear *when they are true and stay true* |
| **Touches** | `App/Browser/DashboardRootView.swift`, `App/Browser/PageStateView.swift`, possibly `ConnectionGateView`; L1 |

## 1. Why

On a healthy cold start the app renders three or four full-screen states in
quick succession, each for a few hundred milliseconds, with hard cuts between
them. Nothing orchestrates that sequence — each screen is an independent view
that happens to be briefly correct:

1. **The gate.** `DashboardRootView.swift:167` shows the dashboard only when
   `hasConnected` is true, and that is set when `statusViewModel.running`
   becomes true (`:186`, `:190`). On a cold start the node is not `Running`
   yet, so `ConnectionGateView` always draws first and is replaced the moment
   the node comes up. No transition, no minimum dwell.
2. **The page states.** `PageState.connecting` renders immediately; only its
   *hint* is delayed, by 8 s (`PageStateView.swift:43`).
3. **The banners.** `gatewayContent` shows `GatewayUnreachableBanner` as soon as
   `homePageAvailability == .unavailable`, which is plausibly true for a few
   hundred milliseconds before the first load succeeds.

**Why this is a real defect and not a cosmetic quibble.** Each of these screens
is a *claim about the system's state* — "you are not connected", "the gateway is
unreachable". Showing them for 200 ms when they are about to be false teaches
the owner to distrust them, which is exactly the opposite of what F4, F8 and
F11 were for. The fast path should look like one transition.

## 2. What the owner sees

A cold launch on a healthy node goes from the system launch screen to the
dashboard, with no intermediate screen appearing and vanishing. When something
really is slow or wrong, the relevant screen appears and **stays**, as it does
today.

Explicitly unchanged: a node that cannot start still shows F8's G7 immediately
once that is known; a gateway that really is unreachable still shows its banner;
the 8 s connecting hint still appears. This feature suppresses *transient*
states, never real ones.

## 3. Non-goals

- **No new artwork, no branded splash animation.** The owner offered a splash
  screen as a worst case, and §4.3 treats it as the fallback it was offered as,
  not the goal.
- **Not slowing the launch.** A grace window must not delay reaching the
  dashboard; it only delays drawing something that is about to be replaced.
- **Not hiding failures.** Any delay measured in hundreds of milliseconds must
  not apply to a state that persists.

## 4. Design

### 4.0 Measure first

Issue #4's count of screens is read from the code. Before choosing, capture the
real sequence with timings on a cold launch:

    xcrun simctl spawn booted log stream --predicate 'subsystem == "net.lixom.latchkey"'

and a slow-motion screen recording on a device. The owner's device timings are
the ones that matter — the node comes up faster on a simulator. Record in §9:
which states appeared, in what order, and for how long each.

That decides whether this is one problem or three, and whether the gate swap
dominates or the banners do.

### 4.1 Preferred: do not draw a state that is about to be replaced

A short grace window before an *intermediate* state is allowed to appear. If
the condition clears within it, that state never draws; if it persists, the
state appears and stays. Applied to the gate swap, `connecting`, and the
availability banners, each with its own window chosen from §4.0's data rather
than a guessed constant.

The subtlety worth stating: this is not a delay on *reaching* the dashboard. It
is a delay on *admitting* an intermediate screen, so the fast path skips them
entirely and the slow path is unchanged.

### 4.2 Then: do not hard-cut between the states that do appear

Where a transition remains visible, it should be a transition rather than a
cut. Cheap, and independent of 4.1.

### 4.3 Fallback: hold the launch surface

`INFOPLIST_KEY_UILaunchScreen_Generation = YES` is already set, so iOS shows a
generated launch screen until the first frame. The fallback is to keep
something with that appearance on screen until the dashboard is ready or a
timeout expires — which is the owner's "splash screen", but framed as *not
tearing the launch screen down prematurely* rather than as adding a new one.

Why it is the fallback and not the first choice: it hides the real state for a
fixed period, so a node that fails in the first 400 ms would be concealed
behind it, and it must be dismantled carefully for the slow paths. It is the
right answer only if §4.1 turns out not to cover the cases §4.0 finds.

**Invariant not to break** (`../../app/AGENTS.md`): whatever replaces the
flashing must not reintroduce a blank or white screen. `RawWebView` sets the
view, scroll and under-page colours (`RawWebView.swift:35-41`) precisely
because `WKWebView` flashes white before its first paint.

## 5. State and migration

None. No persisted value changes.

## 6. End-to-end tests

The hard part is that this feature is about what is *not* drawn, and for how
long. The instrument that already exists: L1's fake dashboard can be made to
answer at a chosen speed, and the app's own log records state changes with
timestamps.

| Test | Suite | Asserts | Shown to fail by |
|---|---|---|---|
| A fast cold launch shows no intermediate state | L1, fast gateway | From launch to page committed, the gate, the connecting state and the availability banner are never reported as having appeared | Removing the grace window: each appears in the log |
| A slow start still shows the connecting state | L1, stalled gateway | The connecting state appears and stays, and the 8 s hint still follows | Applying the grace window to a persisting state: it never appears |
| A node that cannot start still shows G7 immediately | L1, F8's fixture | G7 appears without waiting out any grace window | Delaying failure states: G7 arrives late |

The first is the one worth having beyond this feature: it is the standing test
that the fast path stays quiet as more states are added to this screen.

## 7. Acceptance criteria

1. §4.0's measurement is recorded in §9, before and after.
2. On a healthy cold start, no intermediate state is drawn — instrument: test 1.
3. The slow and failing paths are unchanged in timing — instrument: tests 2 and 3.
4. No blank or white frame is introduced at any point.
5. Olof installs the build and says the launch no longer flashes. The only
   criterion a test cannot stand in for, since "jarring" is what was reported.

## 8. Open questions and owner actions

- **Owner action, and the first task:** a slow-motion recording of a cold
  launch on your device. The simulator's node comes up faster, so its sequence
  is not yours.
- **How long is acceptable to wait before showing a slow-start screen?** A
  400 ms grace hides the flashing; 1 s would hide more but delays honest
  feedback on a genuinely slow start. §4.0's data should settle it, but the
  taste is the owner's.
- **Does the dashboard's own first paint flash?** If the KiroCrew page itself
  renders white or empty briefly, that is upstream of everything here and
  worth separating from our own screens.

## 9. Log

Opened 2026-09-26 from issue #4. The three-to-four screen count in §1 is
inferred from the code; §4.0's measurement replaces it with observation.
