# F15 — Latchkey does not own the page's corners

| | |
|---|---|
| **Status** | **built** (B, 2026-09-24) — awaiting the owner's device check, §7.4. §9 records the threshold, the overlay audit and the evidence |
| **Requested** | 2026-09-24, by Olof, on the first build carrying F9: "I noticed the gear and the notification alarm bell render on top of each other. I don't think latchkey can assume it owns any of the screen to render its own icons on." Plus: "Top bar clears the island. Maybe a bit more than it has to, it could move up a bit." |
| **Revision** | none |
| **Touches** | `app/App/Browser/DashboardRootView.swift`, `app/App/Browser/BrowserView.swift`, new `AppBar.swift` / `AppBarController.swift` / `AppBarRetraction.swift`, `PageScriptSources.appBarObserver`, `testing/harness/dashboard.py` (the shell probe), L1 |

## 1. Why

The settings gear is `.overlay(alignment: .topTrailing)` on the web view, and the
dashboard puts its notification bell in the same corner. They render on top of
each other. That is the reported symptom; the cause is a policy, and the policy
is wrong.

`DashboardRootView` carries **eight overlays at six alignments** —
`.topTrailing`, `.topLeading`, `.top`, `.bottomLeading`, `.bottom` (twice),
`.bottomTrailing` — every one of them painted over the page. Latchkey behaves as
though the screen's edges belong to it. They belong to whatever the gateway
renders, and we do not control that: the dashboard's layout changes between
versions, and F7's premise is that this app works against someone else's tailnet.

This is the same mistake F9 made one layer up. There we assumed the page would
handle an inset it had explicitly said it would not; here we assume the page
leaves its corners empty. Both are Latchkey deciding what a page it does not own
will do.

**Related, and coupled:** Olof also reports the page now sits slightly lower than
it needs to. The reclaimed strip is the full top safe-area inset (59pt on his
14 Pro, 62 on the L1 simulator), while the island's visual bottom is higher than
that. Any answer to §4 changes what that strip is for, so the two are one piece
of work rather than two.

## 2. What the owner sees

Latchkey's controls are always reachable and never sit on top of the dashboard's.
Nothing of the app's is drawn over page content at any corner.

Failing: if the app's chrome cannot be shown without covering the page, it is
the app's chrome that yields — never the page's.

## 3. Non-goals

- **Not negotiating with the page about where its controls are.** Reading the
  dashboard's DOM to place ours around it couples us to its markup and breaks on
  its next release. We already learned this in F9: do not depend on the gateway.
- **Not removing the controls.** Settings must stay reachable; the banners (login,
  machine-auth, gateway-unreachable) are how the app explains itself and F4 exists
  because those states were once invisible.
- **Not restyling the dashboard.** Its corners are its business.

## 4. The decision

Four candidates. **This needs Olof's call before anything is built** — it is a
visible design choice, not something a measurement settles.

**A. A dedicated app bar above the page.** A thin strip Latchkey owns, below the
safe area, holding the gear. The page gets everything beneath it. Predictable and
discoverable; costs perhaps 44pt of page height permanently, on a screen where
the dashboard is already dense.

**B. An auto-hiding bar, Safari's model.** As A, but it retracts as the page
scrolls down and returns on scroll up. The codebase already cites Safari's model
for its edge-to-edge behaviour, and `scrollView.topEdgeEffect` exists for exactly
this feel. Costs no permanent height; costs a little complexity and a moment's
discoverability.

**C. Gesture only.** No persistent chrome at all — settings reached by a gesture
(an edge swipe, or a long press). Zero collision by construction. Worst
discoverability: a control nobody can find is a control that does not exist.

**D. Keep the overlays, move them out of the page's way.** Cheapest, and it does
not hold: "out of the way" is defined by a layout we do not control.

**DECIDED 2026-09-24: B**, by Olof. It satisfies the principle exactly — the app
never draws over the page — without spending page height on a control used a few
times a day, and it matches the model the app already claims to follow. It also
answers the second report: the bar occupies the reclaimed strip's neighbourhood,
so the space stops reading as a gap.

### 4a. The tension B must resolve, discovered in F9

An iOS navigation bar normally *overlays* content and the content insets itself
by the safe area, so nothing is hidden. **That does not work here.** F9 measured
this gateway ignoring `env(safe-area-inset-*)` outside an installed web app — its
`--safe-area-top` is defined only under `display-mode: standalone`. So a bar that
overlays and relies on the page padding itself would cover the page's content, in
exactly the way this spec exists to prevent. We cannot rely on any gateway
insetting itself; F7 says the app must work against tailnets we do not control.

**Therefore the bar displaces: the web view's top edge is the bar's bottom edge.**
The cost is that showing and hiding resizes the web view, and a resize reflows the
page — jarring if it happens on every scroll wobble.

Mitigate with hysteresis, not cleverness: change state only on a deliberate
scroll of some distance in one direction, never on small movements, and never
mid-momentum. Getting this threshold right is most of the feel of this feature.

### 4b. Constraints that are not negotiable

- **The bar must always be reachable.** If the page is too short to scroll, it
  stays shown — a control that can only be revealed by a gesture the page cannot
  perform is unreachable.
- **Hidden must not mean gone for VoiceOver.** A visually retracted bar still
  needs an accessibility path to Settings. On 2026-09-24 this app shipped a
  control that was on screen and not hittable because of accessibility ordering;
  do not add a second way to lose one.
- **Respect Reduce Motion:** no animated retraction when it is on.
- **Do not steal the page's scroll.** The bar observes the web view's scroll; it
  never intercepts or consumes the gesture.

Whichever is chosen, the audit is the same and is the bulk of the work: **every
one of the eight overlays is re-homed or justified in place.** The transient
banners may have a legitimate claim to the top edge — they are full-width, brief,
and about the app's own health — but each must be argued, not assumed.

## 5. State and migration

Nothing persisted, unless B's bar keeps a hidden/shown state across launches —
it should not. ~~It starts shown.~~ Since the 2026-09-24 revision (§9) it
starts absent on a page that scrolls, and shown on one that cannot.

## 6. End-to-end tests

F10 §4.3's obstruction sweep is the natural instrument, extended from "does our
chrome sit under a system obstruction" to "does our chrome sit over the page".

| Test | Suite | Asserts | Shown to fail by |
|---|---|---|---|
| No app control overlaps page content | L1 | For each of the app's hittable controls, its frame does not intersect the web view's frame | Restoring the `.topTrailing` gear overlay: the sweep names it and the rectangles |
| Settings stays reachable | L1 | Whatever §4 chooses, the gear can be found and tapped from the dashboard, in both orientations | Hiding it behind a gesture with no fallback: the test cannot reach it |
| The top strip is no taller than it must be | L1 | The web view's `minY` equals the window's safe-area top plus the app bar's height, and no more | Padding the strip: the assertion reports both numbers |

## 7. Acceptance criteria

1. No hittable Latchkey control intersects the web view's frame — instrument:
   the extended sweep.
2. Settings is reachable in portrait and landscape.
3. Each of the eight overlays is either re-homed or has a written justification
   for staying.
4. Olof confirms on a device that the gear and the dashboard's bell no longer
   collide — the report that opened this.

## 8. Open questions and owner actions

- **§4 is Olof's to decide.** B is recommended; A is the safe conservative choice;
  C is the purest and the least discoverable.
- **How much lower than necessary is the page sitting?** Measure the gap between
  the island's visual bottom and the safe-area inset before adjusting anything —
  the inset is Apple's definition and fighting it usually ends badly. It may be
  that the right answer is "the strip is correct, and the app bar fills it".

## 9. Log

Opened 2026-09-24, from the first device build carrying F9.

### 2026-09-24 — B built

**The shape.** `AppBarColumn` is a `VStack`: the app bar (44 pt, `AppBar`), the
node's banners, then `BrowserView`. The web view's top edge is the bar's
bottom edge (§4a). Retracted, the bar is zero height, the column closes over
it and the page starts at the window's safe-area top. The status-bar strip and
the bar both take the page's canvas colour (F9 §0.1), so the three read as one
surface. The bar has no divider. `DashboardContent` has no overlays left.

**Watching the scroll needs the page, and this is why.** The first plan was to
observe the web view's `UIScrollView` through KVO. The installed KiroCrew
0.7.0 rules that out. Its `index.html` says the shell is "`h-dvh` with
`overflow-hidden` and inner `min-h-0` scrollers", and its CSS has
`body{…overflow:hidden auto}` and `#root{height:100%}`. The document never
scrolls, so the web view's scroll view never moves. A bar driven by it would
never retract on the owner's dashboard: it would quietly be option A.

So the observer is a page script, `PageScriptSources.appBarObserver`. It runs
in the app's own content world, the same way the page-background reporter
does. It stays within §3 and §4b:

- It reads no markup. Its listeners sit on `window` in the capture phase, so
  they see a scroll of *any* element and do not need to know which one.
- It cannot take part in the gesture. Every listener is `passive`, and none
  calls `preventDefault` or `stopPropagation`. The Node test enforces all of
  this against the exact injected text (`scripts/test-app-bar-observer.js`).
- If it fails, the bar stays shown. A page that never reports anything never
  retracts the bar.

It posts the finger's travel in screen points, coalesced to one message per
frame, and the largest vertical scroll range of anything that scrolled during
the touch. A change in viewport size re-bases the finger. That matters because
the bar's own retraction moves the page 44 pt under a finger that has not
moved, and without the re-base the page script would count that as travel.

**The hysteresis: 64 pt of finger travel, in one drag, in one direction.**
The rules are in `AppBarRetraction`:

- Only finger travel counts. Momentum sends no touches, so nothing changes
  mid-momentum. A page that scrolls itself also changes nothing, such as a
  chat following new messages.
- Travel restarts at each touch-down and whenever the finger reverses, so
  nudges made while reading never add up.
- Retracting needs something that actually scrolled, with a range larger than
  the bar. A page too short to scroll keeps the bar (§4b). So does a page that
  would stop being scrollable as soon as the bar gave it 44 pt.
- Returning needs only the finger. A 64 pt downward drag brings the bar back
  on any page, whether it scrolls or not. This is what makes a retracted bar
  always recoverable.

**Why 64.** It is above the 10–40 pt corrections a reader makes while holding
a place, and below the travel of one ordinary scrolling drag (100 pt or more).
It is also about one and a half bar heights: moving the page by 44 pt should
take clearly more than 44 pt of intent. This is reasoned, not measured on a
hand. The feel needs the owner's thumb on a device. It is one constant,
`AppBarRetraction.threshold`. If it feels twitchy, raise it. If it feels
sticky, lower it. Do not switch to cumulative travel, which would let nudges
add up.

A known cost, chosen on purpose: a 64 pt downward drag of something that does
not scroll also reveals the bar. Dragging a card down a board is an example.
That costs one reflow. The alternative is a bar that some page cannot bring
back.

**Hidden is not gone for VoiceOver.** While VoiceOver or Switch Control is
running, the bar never retracts. Turning either one on brings a retracted bar
back immediately (`AppBarController`, which watches both status
notifications). For those users Settings is always on screen. It is also
first in the accessibility order: the bar is the column's first child, at the
safe-area top, and nothing overlaps it. L1 cannot switch VoiceOver on, so
`-UITestAssumeVoiceOver` stands in for it.

The first L1 run caught one more way to lose a control. The first version
clipped the bar to zero height with `accessibilityHidden`. That still laid out
the gear, above the bar and under the status bar, and XCUITest found it
hittable there while the bar was retracted. An invisible control that can
still be hit is exactly what §4b forbids. Retracted now **removes** the bar's
controls from the tree. The hardware-keyboard path to Settings (⌘,) is
unchanged.

**Reduce Motion:** `AppBar.animation(reduceMotion:)` returns no animation, so
the bar and the page move in one step. There is **no end-to-end test** of this:
XCUITest cannot turn Reduce Motion on, and "no animation" is a timing claim that
a UI test would only guess at.

**The eight overlays.** Every one was re-homed. None stays on the page.

| # | Was | Now | Why |
|---|---|---|---|
| 1 | `.topTrailing` settings gear | **app bar**, trailing | The collision that opened this spec. Now full opacity with a 44 pt target. The 0.45 fade existed only because it sat on the page. |
| 2 | `.topLeading` "Dashboard" (return from a popped-out page) | **app bar**, leading | Navigation. Retracting with the bar is right, as Safari's back button does. |
| 3 | `.top` "Signed out — Sign in" capsule | **app bar**, between the other two | It is the only sign-in control (R22), so it **pins** the bar shown while it is there (`setPinned`). |
| 4 | `.bottomLeading` `page-connecting-shown-count` | behind, status-bar corner | Test instrument, Testing builds only. |
| 5 | `.bottom` `session-auth-required-count` | behind, status-bar corner | Test instrument, Testing builds only. |
| 6 | `.bottomTrailing` "Connected Browser" | behind, status-bar corner, **now Testing builds only** | This one **shipped**: an invisible element that VoiceOver read over the dashboard's bottom-right corner. Every use is a UI test's `.exists` (L2, lifecycle and inherited suites). |
| 7 | `.bottomLeading` `tcp-chaos-test-status` | behind, status-bar corner | Test instrument, set only by a chaos test hook. |
| 8 | `BrowserView`'s `.topLeading` `WindowSafeAreaProbe` | same background group | It reads the window, so where it sits does not matter. It was on the page's corner for no reason. |

Items 4–8 are 1 pt text at 0.01 opacity in the status-bar strip's top-leading
corner, with hit testing off. The first attempt put them *behind* the web view,
and that was not enough. L1's sweep reported all four texts as hittable **on
the page**: a view the page covers still wins accessibility's hit test there.
That is the same ordering trap as the F9 regression.

**The banners (§4b's "argue it").** Login-required, machine-auth,
gateway-unreachable and the expiry warnings stay where they were, and none of
them overlays the page. They were already members of the layout (R31 review).
They **displace** the page exactly as the bar does, so they sit alongside it
rather than on it, and they cannot hide the dashboard's bell. They take the top
edge (the expiry warnings the bottom) for four reasons:

- They are about the app's own health, not the page's content.
- They are full-width, with no corner of their own to collide with.
- They are brief: each goes away by itself when the state clears.
- While they show, the page is often the thing that has failed.

They do **not** go in the bar and do not retract. A state the owner must act
on cannot be hidden by a scroll. The bar pins only for the sign-in capsule.
The login, machine-auth and gateway-unreachable banners do not pin it, because
they stand on their own, and gateway-unreachable carries its own "Change"
button into Settings. Their 52 pt trailing padding ("room for the gear") is
gone, because the gear no longer floats over them.

**§8's "sits lower than needed".** Not changed. The page now starts 44 pt below
the safe-area top, and the strip above it is the bar. That is §8's own
prediction: "the strip is correct, and the app bar fills it". It still needs
the owner's eye on the device.

**Tests (§6), each shown able to fail.** L1 adds two tests, and one existing
test is updated:

- `testNothingOfOursSitsOnThePageAndSettingsIsReachable` covers all three of
  §6's rows, in portrait and then landscape, on one launch:
  - It takes one accessibility snapshot. Everything outside the web view's
    subtree that is a control or text and overlaps the web view's frame is
    asked `isHittable`, and none may be.
  - The gear must be hittable, and tapping it must open Settings and close it
    again.
  - The web view's `minY` must be `windowSafeTop + 44`, with 44 hard-coded so
    a padded bar cannot redefine it.
  - Then it drags the short fake dashboard up 240 pt, and the bar must stay.

  Measured: portrait `webViewFrame=(0, 106, 402, 734) windowSafeTop=62`,
  landscape `(62, 44, 750, 338) windowSafeTop=0`.
- `testTheAppBarRetractsOnADeliberateScrollAndComesBack` runs on the new
  `root=shell` probe (`testing/harness/dashboard.py`). The probe is KiroCrew's
  layout: a `100dvh` shell whose body never scrolls, an inner scroller, and a
  button in the header's top-trailing corner where the bell is. The test checks
  four things:
  - A 30 pt nudge changes nothing.
  - A 240 pt drag up retracts the bar: `minY` goes from 106 to 62, and the page
    reports `scrollTop=251`, so the drag reached it and was not consumed.
  - A 240 pt drag down brings the bar back, with the gear hittable.
  - Relaunched with `-UITestAssumeVoiceOver`, the same drag scrolls the page
    (`scrollTop=230`) and the bar stays at 106.
- `testInsetProbesReportWhatThePageIsTold` (F9) now expects
  `minY = safeTop + 44`. The probes are still told 0 px, and the strip pixel is
  still the page's colour.

Mutations, each built and run (`app/build/f15-runs/`):

| Mutation | Failing assertion, as printed |
|---|---|
| The pre-F15 gear as `.overlay(alignment: .topTrailing)` on the web view | `portrait: nothing of Latchkey's may sit on the page (web view (0.0, 106.0, 402.0, 734.0)); on it: ["restored-overlay-gear (359.3, 110.0, 32.7, 32.7)"]` |
| The gear removed from the bar (Settings only behind ⌘,) | `portrait: the gear is on screen and tappable` |
| The bar padded 8 pt | `("114.0") is not equal to ("106.0") … webViewMinY=114.0 windowSafeTop=62.0 barHeight=44.0` |
| The VoiceOver guard removed | `("62.0") is not equal to ("106.0") … VoiceOver: the bar never retracts` |
| The page observer not installed | `("106.0") is not equal to ("62.0") … a deliberate drag up retracts the bar` (the page still scrolled, to 250) |

Host tests in `make test-policy`:

- `scripts/test-app-bar-retraction.sh`, 23 checks of the policy. It fails 2 of
  23 when the "something scrolled, with more range than the bar" condition is
  removed.
- `scripts/test-app-bar-observer.js`, 22 checks of the injected script. It
  fails on all five listeners when `passive` is flipped to `false`.

The retraction test's first run also confirmed that WebKit delivers `touchmove`
to a passive capture listener while an inner scroller is scrolling natively.
The whole design rests on that, and it was an assumption until then.

**Suites.**

- `scripts/test-offline.sh --build`: 17 of 17 passed, and the R1 disk and log
  scan passed, in **321 s** against the 240 s budget. The previous run was
  257 s. The two new tests take about 60 s of that (27.6 s and 32.3 s). The
  budget is unchanged.
- `make test-policy`: green.

Both runs used the working tree before two comment-only edits.

### 2026-09-24 — revised: the bar is absent in the steady state

Olof, on the first build of B: a permanent full-width band for one cogwheel is
a bad trade. The bar is now **absent** until asked for. The page fills the
screen as it did before F15; a deliberate scroll up (the finger moving down
64 pt) brings the bar in, and a deliberate scroll down takes it away. Same
displacement, same 64 pt hysteresis, same finger-only input; only the default
is inverted.

**What that costs, and how it is paid.** With the bar hidden by default, a
page that cannot scroll would have no scroll up to bring it in: the gear would
be gone (§4b). The touch-time scroll range the policy used before is no longer
enough, because the answer is needed before anyone touches the page. So the
page script now also reports the page's **extent**: the largest scroll range of
the document or of any element whose `overflow-y` lets it scroll (form controls
aside), measured at most every 500 ms after the document loads, resizes,
mutates or scrolls, posted when it changes and always at `load`. It reads
layout, never markup or text. The rules (`AppBarRetraction.extent`):

- A new document counts as not scrolling until it reports, so the bar is shown
  first and a page whose script never runs keeps it.
- Shown, the page must have more range than the bar (44 pt) to lose it.
  Hidden, it keeps the page until it has no range left. So the 44 pt the bar
  gives back can never bring it straight back.
- A drag that scrolled something with more range than the bar is proof as
  well, whatever the last report said.

VoiceOver, Switch Control, a state page and the sign-in capsule still force the
bar on. What changed there: a drag made while one of them holds is discarded
rather than remembered, and when it clears the bar returns to the steady state.

**The keyboard.** It resizes the web view (F13, and `42af25d` shipped a black
screen from a keyboard inset taken twice). With the bar default-hidden it could
also move the bar: the shrunken viewport can make a short page scroll, and the
bar would hide under the field being typed into. So `AppBarController` holds
extent reports from `keyboardWillShow` to `keyboardDidHide`, and applies the
last one when the keyboard goes. The finger still shows and hides the bar with
the keyboard up. The bar changes only the web view's top edge, and F13's bottom
padding keys on the stack's bottom inset, which the bar does not touch.

**Tests.** Updated, not added:

- `testTheAppBarRetractsOnADeliberateScrollAndComesBack` (shell probe): the
  "starts shown" expectation is **inverted**, not weakened. The bar starts
  absent (`minY` = safe-area top) and the gear is not hittable. A 30 pt nudge
  down changes nothing; a 240 pt drag up scrolls the page and leaves the bar
  away; 240 pt down brings it in with the gear, and the page reports it
  scrolled back (not consumed); 240 pt up takes it away again. VoiceOver: shown
  from the start and through the drag, as before.
- `testNothingOfOursSitsOnThePageAndSettingsIsReachable`: first, untouched,
  the fake (too short to scroll) must have the bar and a hittable gear. Then in
  each orientation one drag down brings the bar in before the sweep, the
  `minY` check and the Settings round trip: the gear is at most one gesture
  away.
- `testTypingInThePageKeepsItOnScreen` runs twice. On the fake, as before, the
  bar is shown and must stay with the keyboard up. On the shell probe, which
  now has a text field in its header, the keyboard comes up with the bar
  absent, then a scroll up shows it and a scroll down hides it; at each step
  the keyboard is still up, the page starts at the right edge, ends within
  120 pt of the keys, is drawn, and the field is hittable.
- Host: `scripts/test-app-bar-retraction.sh` rewritten for the new default
  (43 checks, including the extent hysteresis, the keyboard hold and a new
  document), and `scripts/test-app-bar-observer.js` covers the extent
  measurement (39 checks).


Measured (`scripts/test-offline.sh --build`): the shell starts at `minY=62`,
the safe-area top, and the VoiceOver launch at 106. With the keyboard up the
web view ends at 478 in every state, 112 pt above the keys (590) as in
`42af25d`: shell `(0, 62, 402, 416)` hidden, `(0, 106, 402, 372)` after the
scroll up, `(0, 62, 402, 416)` after the scroll down, keyboard still up and the
page's blue drawn. The fake keeps its bar with the keyboard up,
`(0, 106, 402, 372)`.

Mutations of the policy, host-only: treating an unreported page as scrolling
fails 3 of 43 checks; dropping the extent hysteresis fails 2 of 43.

**Suites.** `scripts/test-offline.sh --build`: 18 of 18 passed and the R1 scan
passed, in **311 s** against the 240 s budget (272 s before; the typing test's
shell pass adds a launch). `make test-policy`: green.
