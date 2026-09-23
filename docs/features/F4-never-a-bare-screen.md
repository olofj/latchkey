# F4 — Never a bare screen: connecting, scanning and empty states

| | |
|---|---|
| **Status** | spec |
| **Requested** | 2026-09-23, by Olof: "The UI has some blank screens where you don't know what's going on, such as when there's no gateway available and all you have is the gear in the top right. That should be improved." — and earlier the same day, "I entered byskebox manually, screen went blank. Not a great UI experience if it's stuck loading something." Plus: "Make sure the UI indicates the scan is going on." |
| **Revision** | none; a gap, not a change of documented behaviour |
| **Supersedes** | F2 (the connecting state), folded in here: both live in the same views, and F2 had no code yet |
| **Touches** | `App/Browser` (`DashboardRootView`, `BrowserView`, `BrowserViewModel`), `App/Discovery/GatewayPickerView`, the L1 offline and L2 discovery suites |

## 1. Why

Three separate holes, all showing the same thing to the owner: a white screen
with a gear in the corner.

**A. The silent startup retry.** `App/Browser/BrowserViewModel.swift:378`
`retryStartupLoadIfAppropriate` swallows a transient startup failure and
retries the load **once a second until a deadline**, with no UI at all. On the
first device run the gateway's tailnet grant was missing, so every SOCKS dial
was dropped:

```
socks5: dial tcp byskebox…:443 failed: context deadline exceeded
```

Each failure was "transient", so the app retried quietly and the screen stayed
blank for as long as the retry window lasted. Nothing said it was still trying,
and nothing said where to look.

**B. Nothing painted, no error yet.** Even outside the retry path, a main-frame
load that is merely slow paints nothing. The error overlay
(`nav-error-overlay`) only exists once WebKit gives up.

**C. The picker can be dismissed over emptiness.** With no gateway chosen the
app shows `GatewayPickerView` (`DashboardRootView.swift:197`), which is right —
but the picker is also presented as a **sheet** from Settings → Gateway and
from the unreachable banner's *Find*. Cancel that sheet before anything has
ever loaded and what is left is a blank page and the gear.

**D. A sweep in progress is nearly invisible.** The picker shows "Looking for
Kiro Crew gateways on your tailnet…" only while `phase == .probing &&
gateways.isEmpty` (`GatewayPickerView.swift:48`). Tap *Search again* when rows
are already listed and nothing indicates a scan is running — and since R39 a
sweep now takes up to 12 s.

## 2. What the owner sees

**Connecting** (A and B): while a main-frame load is in flight and nothing has
painted — including through the silent retries — a centred state: an indicator
and "Connecting to byskebox over your tailnet…". After 6 s a second, smaller
line: "Still trying. A new device may not be allowed to reach this gateway yet.
Settings → Status shows this device's address." It disappears the instant
content paints.

**Gave up** (A): when the retry deadline passes, the error state owns the
screen and offers *Try again* and *Choose another gateway*. Today the retry
window simply ends and the ordinary error page appears with no way to change
gateway.

**No gateway** (C): a centred empty state — "No gateway chosen", a line
explaining that a gateway is a computer on the tailnet running Kiro Crew, and
two buttons: *Find gateways* and *Enter one by name*. Both open the picker.
Reachable at any time; it is what sits behind a dismissed picker sheet.

**Scanning** (D): whenever a sweep runs, the picker shows progress: "Checking
N computers on your tailnet…" with the count from `candidateCount`, results
streaming in as rows as they answer, and *Search again* disabled while it runs.
When a sweep ends with nothing: "Checked N, none answered" plus the existing
guidance line.

**Every state is named in the app's log**, so a suite and a device run can both
tell which one was on screen.

## 3. Non-goals

- No diagnosis of *why* the tailnet refused: the connecting hint points at
  Settings → Status, it does not try to explain grants (that is the runbook's
  job, and possibly a later feature).
- No spinner over a painted page: a same-document navigation, a subresource, or
  the page's own WebSocket reconnect must never flash the connecting state.
- No change to the retry policy itself (cadence or deadline). This feature makes
  it visible, not different.
- No new controls over the web view unless taps are verified: a Button at
  opacity < 1 over a `WKWebView` receives no taps (M8 finding). The empty and
  connecting states have no web view under them, so their buttons are fine.

## 4. Design

**`App/Browser/BrowserViewModel.swift`**
- A published `pageState` enum: `.idle`, `.connecting(host: String, since: ContinuousClock.Instant)`, `.painted`, `.failed(…)`. Derived from the existing callbacks: `.connecting` on a main-frame provisional navigation, `.painted` on `didCommit`/first paint, `.failed` where `navigationError` already runs.
- `retryStartupLoadIfAppropriate` keeps the state at `.connecting` across retries instead of leaving it undefined, and logs each retry as it already does.
- When the retry deadline passes, the error path runs as usual — so the "gave up" screen is the existing overlay plus a *Choose another gateway* action.
- The hint threshold is a named constant, `connectingHintDelay = .seconds(6)`, commented: past a warm load (a painted dashboard is under 1 s on a direct path, ~2 s relayed) and well short of a dropped dial's own failure, which took tens of seconds on the device.

**`App/Browser/BrowserView.swift`**
- Renders the connecting state from `pageState`, `accessibilityIdentifier("page-connecting")`, with the hint line as `page-connecting-hint`. VoiceOver reads both; the indicator is not the only signal. Correct in dark mode.

**`App/Browser/DashboardRootView.swift`**
- A `NoGatewayView` for the `!homePage.hasGateway` case, shown **behind** the picker rather than instead of it, so dismissing the sheet lands on it: identifier `no-gateway`, buttons `no-gateway-find` and `no-gateway-manual`.
- The error overlay gains `nav-error-choose-gateway`, which opens the picker through the same single-presentation path Settings and the banner already share (M5 review: two presentations must not overlap).

**`App/Discovery/GatewayPickerView.swift`**
- The progress row shows whenever `discovery.phase == .probing`, not only when no rows are listed yet; text from `candidateCount`; identifier `gateway-scanning`.
- *Search again* is disabled while probing (it already is) and the row carries the count so a test can read it.
- The finished-with-nothing text names how many were checked.

**Untouched:** the split tunnel, `allowFailover`, ATS, and the node's own
banners (login, approval, expiry), which already own the screen when they
apply and must keep priority over the connecting state.

## 5. State and migration

None. Nothing new is persisted; `pageState` is per-tab and in memory.

## 6. End-to-end tests

| Test | Suite | Asserts | Shown to fail by |
|---|---|---|---|
| A stalled load shows the connecting state, with the host named | L1 offline (stub proxy blackholed) | `page-connecting` appears within 1 s and names the host; no `nav-error-overlay` yet | removing the state: the screen stays bare |
| The hint appears while the silent retries run | L1 offline | `page-connecting-hint` appears after the threshold and **while the log shows at least two "retrying" lines** — the retry path is what hid this | leaving `pageState` undefined across retries |
| Giving up offers another gateway | L1 offline | after the retry deadline, `nav-error-overlay` with `nav-error-choose-gateway`; tapping it opens the picker | omitting the action; the test taps it |
| A painted dashboard never shows the connecting state | session (M4), real KiroCrew bundle | `page-connecting` absent through the page's own reconnect, refetches and a `/__drop_ws` cut | driving the state from subresource loads |
| Dismissing the picker lands on the empty state, not a blank screen | discovery (L2) | with no gateway, cancel the picker → `no-gateway` visible with both buttons; `no-gateway-find` reopens the picker | reverting to today's layout: nothing but the gear |
| A sweep is visible while it runs, with the count | discovery (L2) | `gateway-scanning` present during the sweep (the harness's stalling peer keeps it ≥ 4 s) and gone when it ends; its label carries the candidate count | restoring the `gateways.isEmpty` condition, which hides it on a re-scan |
| Search again shows progress even with rows already listed | discovery (L2) | after a first sweep found a gateway, tapping *Search again* shows `gateway-scanning` | the same regression as above |
| No state leaves only the gear | discovery (L2) | a checklist pass over: no gateway, sweep running, sweep empty, gateway chosen but unreachable, load in flight, load failed — each asserts one named identifier on screen | deleting any one state's view |

## 7. Acceptance criteria

- In every state enumerated in §2, a named identifier is on screen; the
  checklist test enforces it.
- The connecting state appears within 1 s of a main-frame load that has not
  painted, survives the silent retries, and is gone on paint.
- A sweep is visibly in progress for its whole duration, including re-scans.
- The owner can always reach the gateway picker without going through Settings:
  from the empty state, and from a failed load.
- L1, discovery and session suites stay green.

## 8. Open questions and owner actions

- Wording is the author's; the owner may want the hint blunter or shorter.
- Should the connecting state show which port is being tried once F1 lands?
  Probably yes, as `byskebox:8443` — decide when F1 is in.
- A later feature could name the actual cause (locked-out node, no grant) by
  reading the node's own health; recorded as an open question in DECISIONS
  rather than guessed at here.

## 9. Log

- 2026-09-23: specified, superseding F2. The bugfix Olof asked for in the same
  message — the probe timeout — landed separately as R39 (4 s per probe, 12 s
  per sweep; app `8a5220b51`), because it needed no UI work.
