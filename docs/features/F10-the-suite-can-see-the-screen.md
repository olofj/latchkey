# F10 — The suite can see the screen

| | |
|---|---|
| **Status** | **built** 2026-09-27: §4.2 (2026-09-24), §4.3 and §4.4 in L1, §4.5 in the session suite; §4.1 is F9's. Revised before building (§4.5), and §4.5 revised again while building: the accessibility tree could not see the page (§9). Criterion 4 met by §4.5. Open: the audit's 37-finding baseline, each an owner item (§8) |
| **Requested** | 2026-09-24, by Olof, after reporting F9 from a device: "you should have been able to find that yourself. Test coverage miss, please introspect and come up with (high value and not just silly checkbox) test cases for these kind of issues." |
| **Revision** | none |
| **Touches** | `app/UITests/` (`SafeAreaAudit.swift`, `OfflineHarnessTests`, `SessionTests`), `testing/harness/dashboard.py`; test hooks only in the app: §4.3's probe (`RawWebView.swift`, `ConnectionGateView.swift`, `DashboardRootView.swift`) and §4.5's `App/Browser/PageSweep.swift`; the shard duration tables |

## 1. Why

Two of the nine specs in this directory are layout bugs the owner found with his
own eyes on his own phone, and neither was findable by any suite:

- **F5** — the instance chips collide in portrait.
- **F9** — the page bleeds under the Dynamic Island.

That is a pattern, and the cause is a *good* rule with an edge nobody noticed.
`README.md` in this directory says: "Prefer server-side evidence (what the fake
dashboard or the harness saw) over reading the screen." That is right, and it is
why these suites do not flake. But it also means **nothing in this repository
asserts where anything is**, so a whole class of defect had no instrument at all.
Measured 2026-09-24:

```
$ grep -rn 'orientation\|landscape' app/UITests/            # (nothing)
$ grep -rn 'performAccessibilityAudit' app/UITests/         # (nothing)
$ grep -rn '\.frame\b\|minY\|maxY'  app/UITests/            # keyboard handling only
```

Frames are read only to decide where to tap and whether the chat input moved
(`LatchkeyUITests.swift:624`, `:666`, `:746`). Geometry is a means, never a
subject. Every suite runs portrait, on one simulator.

**And the fixture is more forgiving than the product, in the exact dimension of
the bug.** This is the finding that matters most, because it would have defeated
a *correct* new test written in the obvious place:

| | viewport meta |
|---|---|
| shipped frontend (`kiro_crew/static/dist/index.html:29`) | `width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no, interactive-widget=resizes-content, viewport-fit=cover` |
| fake dashboard (`testing/harness/dashboard.py:89`) | `width=device-width` |

The fake never asks for edge-to-edge, so it cannot be clipped by an island, so a
safe-area test in L1 would have passed against the broken app. A fixture simpler
than reality hides precisely the bugs that reach the owner.

## 2. What the owner sees

Nothing, when this works: he stops being the first to notice that something is
under the island, off the bottom of the screen, or clipped in landscape.

Failing: each check names the element and the obstruction, so a failure is
actionable without a screenshot — "`gateway-refresh` (x, y, w, h) intersects the
top unsafe region (0, 0, w, 59)".

## 3. Non-goals

- **No screenshot or snapshot diffing.** It fails for the wrong reasons — a font
  metric, an animation frame, a new OS — so it gets blanket-rebaselined on red,
  and a suite that is rebaselined on red launders regressions instead of
  catching them. Every check here is a computed number with a stated rule.
- **Not a device matrix.** The point is coverage of *geometry classes* (an
  inset-bearing top edge, a home indicator, both orientations), not of hardware.
- **Not auditing the page's internals as native elements.** A `WKWebView` is one
  element to XCUITest; the page's own layout is reachable only by asking the page
  (§4.1), which is the existing server-side-evidence idea pointed at geometry.

## 4. Design

Four checks, ordered by value per unit of maintenance. §4.2 is the keystone: it
is what keeps the other three honest.

### 4.1 The app must not lie to the page about its insets

Covered by **F9 §6** and not duplicated here: probe pages report their computed
`env(safe-area-inset-*)` and viewport height to the harness, and the test asserts
numeric equality with the device's real insets. Numbers, not pixels; it cannot
rot, and it catches the rotation and keyboard cases for free.

### 4.2 The fake must be no more forgiving than the product

A host test (`app/scripts/test-fixture-parity.swift`, run by `make test-policy`)
that reads **both** documents and fails when they disagree on the things that
change layout:

- the `viewport` meta's `viewport-fit` and `interactive-widget` values;
- whether the document uses `env(safe-area-inset-*)` at all.

Real source: the installed `kiro_crew/static/dist/index.html` — the same file
`scripts/test-session.sh` already pins a bundle version of, read and never run.
Skip with a clear message when it is absent, rather than passing quietly.

This is the check that would have made F9 findable *before* the device install,
and it keeps working when KiroCrew 0.7 changes its viewport: the suite tells us,
instead of the owner.

### 4.3 Nothing of ours may sit under a system obstruction

`app/UITests/SafeAreaAudit.swift`, a helper called at the end of existing flows
rather than a suite of its own:

```
assertNothingObstructed(app, exempt: [...])
```

For every hittable element belonging to the app's own chrome, assert its frame
does not intersect the unsafe regions, derived at runtime from the window's safe
area rather than hard-coded. Deliberate exemptions are named with a reason — the
web view itself is edge-to-edge by design (F9), so it is exempt and its *content*
is covered by §4.1 instead.

Runs in **both orientations**: rotate, re-assert, rotate back. Orientation is a
dimension over existing checks, not a second copy of the suite — F5 was a
portrait-only bug, and rotating for the geometry sweep alone costs seconds.

**As revised (2026-09-27).** Two details the first draft left open:

- **The unsafe regions need all four insets.** The F9/F11 probes report the
  window's top and bottom only, and landscape's obstructions are the sides.
  A third probe, `window-safe-insets` (value `top=T left=L bottom=B
  right=R`), sits beside them under the same `-UITestReportSafeArea` flag,
  on the gate and on the dashboard. The window's insets do not change while
  a sheet is up, so Settings is swept with the insets read before it opened.
- **Scrolling content is exempt, fixed chrome is not.** A row of a list that
  scrolls under the home indicator is how iOS lists work: the owner scrolls
  it into view. An element with a scroll view, table or collection view
  among its ancestors is therefore checked only against the sides; anything
  else against all four edges. Exemptions beyond that are named, with a
  reason, at the call site.

Flows swept, each in portrait and landscape: the gate, the dashboard with
its bar in, Settings over it, and the error page. The picker is swept in
portrait: it is one presentation of the same sheet machinery as Settings.

This check has **no retroactive catch** among the bugs so far (§4.5 says
why), and is kept because it is cheap and aimed at a class that has come
close: the gear's placement in F15 and the gate's button in F11 were both
native chrome at an edge. It is the net under those, not the answer to F5.

### 4.4 The system's own audit, for free

`app.performAccessibilityAudit(for: [.textClipped, .hitRegion, .elementDetection,
.contrast])` at the end of the same flows. Apple maintains the rules, so it
catches clipped labels, unreachable controls and too-small targets at near-zero
maintenance cost, including cases nobody here thought to write down.

It does **not** see inside the web view, which is exactly why §4.1 and §4.2 carry
the page's half. Findings that are genuinely intended get an explicit
`XCTIssue` suppression with a comment, never a blanket disable.

### 4.5 The page's own content must not collide at phone width (added 2026-09-27)

Criterion 4 asks whether §4.3 would have caught F5, and the specs answer it
without a run: **no**. F5 was two of the *page's* elements drawn over each
other (F5 §1: "Switch instance" on top of the list-failed chip), inside the
web view, which §4.3 exempts by design and §4.4 does not see into. Of the
layout bugs the owner found: F9 is §4.1's; F15 (the gear over the page's
bell) has its own standing test; F5 has a test for **its one row**
(`testTheInstanceChipsDoNotOverlapInPortrait`). Nothing covers the class
F5 belongs to — the real frontend's own content colliding at the widths a
phone gives it — so the next row that overflows reaches the owner exactly
as F5 did.

So the class gets its own check, on the one fixture that can hold it:

- **Where:** the session suite, on the real pinned bundle. The fake
  dashboard cannot stand in: §4.2 aligns its viewport with the product's,
  not its layout.
- **When:** in the shared signed-in run (F14), right after the instance bar
  is read, in portrait and again in landscape — the page as the owner meets
  it, signed in, at rest. No new launch.
- **What is collected — revised while building (§9):** not the
  accessibility tree. For web content it has no clipping and no z-order, so
  on the real bundle it reported a chip scrolled out of the instance bar,
  and the hero heading scrolled under the session header, as collisions
  the screenshots showed were not drawn at all. The page is asked instead:
  a test-hooks-only script (`App/Browser/PageSweep.swift`,
  `-UITestPageSweep`), run by the app in its own content world every
  second and published as the value of a `page-sweep` element. Its items
  are controls and elements with their own text (not inside a control),
  measured tight, clipped by every `overflow` ancestor and the viewport,
  and kept only if drawn: not hidden by `display`, `visibility` or
  opacity up the ancestry, at least 2 px each way, and topmost at one of
  five points inside it (`elementFromPoint`).
- **What is asserted:** no two drawn items overlap, each rect inset by
  1 px so a shared edge is not an overlap (F5 §9's rule), unless one
  contains the other in the DOM. A failure names both items and their
  rects. The "leaves the web view sideways" check of the first draft is
  gone: clipped to what is drawn, nothing can.

Shown to fail the way F5's own test was: a build with the chip style's
install removed must fail this check **by naming the pair F5 named** —
without being told where to look. That is criterion 4.

**Invariants this must not break** (see `../../app/AGENTS.md`): no change to the
split tunnel, `allowFailover`, ATS, or D1; no vendored-tree change.

## 5. State and migration

Nothing persisted. All checks derive from the running app and the two documents
in §4.2.

## 6. End-to-end tests

The deliverables here *are* tests, so this section is about how each is shown
able to fail — which for a test is the only evidence that it works.

| Test | Suite | Asserts | Shown to fail by |
|---|---|---|---|
| Fixture parity (§4.2) | `make test-policy` | The fake's viewport meta matches the real frontend's on `viewport-fit` and `interactive-widget`, and both use `env(safe-area-inset-*)` | Its current state: today's fake declares only `width=device-width`, so the check fails **before** the fake is fixed. That red is the proof, and fixing the fake is part of this work |
| Obstruction sweep (§4.3) | L1, portrait + landscape: `testTheGateIsClearOfTheScreensEdges`, and inside `testNothingOfOursSitsOnThePageAndSettingsIsReachable` (dashboard, Settings) and `testTheErrorPageOffersRetryAndAnotherGateway` (error page, picker) | No hittable chrome element reaches an unsafe region (§4.3's rules) | As built: `.ignoresSafeArea()` on the gate's container. Portrait names `login-button` reaching the bottom band; landscape names it and 12 others reaching the sides (§9) |
| Accessibility audit (§4.4) | L1, the same flows | No finding outside the first run's baseline (`SafeAreaAudit.auditBaseline`) for `.textClipped`, `.hitRegion`, `.elementDetection`, `.contrast` | As built: the gate's "What happens next" held to 60 pt on one line; the audit names it, Text clipped, in both orientations (§9) |
| Inset truthfulness (§4.1) | L1 | See F9 §6 | See F9 §6 — reverting `BrowserView.swift` makes the probe report `0px` |
| Page collision sweep (§4.5) | Session, real bundle, portrait + landscape | No two of the page's labelled leaves or controls overlap, and none leaves the web view sideways | The chip style's install removed: the sweep names "Switch instance" and the list-failed chip, as F5's test does |

## 7. Acceptance criteria

1. The fixture-parity check fails against today's `dashboard.py` and passes once
   the fake's viewport matches the product's — instrument: `make test-policy`.
2. With the fake corrected, the F9 inset test still fails against pre-F9 app code.
   If it does not, §4.2 did not actually close the gap — instrument: run both.
3. The obstruction sweep runs in both orientations in L1 and adds < 30 s.
   — **Not met as written:** with §4.4's audit, which runs at the same
   points, the three carrying tests grew by 33.5 s in total (gate run
   8.6 → 14.6 s, F15's test 25.4 → 37.9 s, the error-page test 18.6 →
   33.6 s), on the four-shard default about a quarter of that each. The
   audit is most of it; §4.3 alone was not timed apart.
4. Re-running the F5 scenario (portrait instance chips) with the sweep in place
   reproduces a failure on the code as it was before F5's fix — the honest test
   of whether this would have caught the *previous* one, not just the last one.
   — Revised: §4.3 cannot (§4.5), so the criterion is §4.5's. With the chip
   style's install removed, the page sweep fails naming F5's pair, without
   being pointed at the instance bar — instrument: the session suite, run on
   that build. — **Met** (§9): it names the chevron and the list-failed
   chip's "Ask the agent" part; F5's own test names that chip's "not found"
   part. Same pile-up, found without being told where to look.
5. The page sweep adds nothing but a snapshot per orientation to the shared
   signed-in run: < 5 s on the session suite. — Met: the run that carries
   it measured 30.0 s before and 34.2 s after (it now waits for two
   agreeing reports per orientation).

## 8. Open questions and owner actions

- Criterion 4 is the one that decides whether this is worth its keep. If the
  sweep cannot catch F5 retroactively, the design is aimed at the wrong thing and
  should be reconsidered rather than shipped for the sake of coverage.
  — Reconsidered 2026-09-27 (§4.5): it cannot, so the design gained the check
  that can, and §4.3 is kept as the cheaper net it is.
- `performAccessibilityAudit`'s findings on an app nobody has audited before are
  unknown; the first run may be noisy. If it is, the answer is to fix or
  explicitly suppress each finding with a reason — not to narrow the audit types
  until it goes quiet.
- **Owner action: the audit baseline.** The first run reported 37 findings
  on our own screens. None is suppressed as intended; they are held in
  `SafeAreaAudit.auditBaseline` so that a *new* finding fails, and each is
  open here:
  - **Contrast** (Apple's "failed" or "nearly passed"): the gate's
    sign-in button and its last step; the error page's three buttons and
    Details; the picker's Cancel, proxy warning, "sweep done", manual Use,
    and its section headers; Settings' Done, the rename warning and its
    section headers. Most are system styles (tinted buttons, glass bar
    buttons, grouped-form headers) the app does not colour itself; fixing
    them is a choice of tint and warning colours, which is yours.
  - **Text may clip at larger Dynamic Type:** every text on the error page
    (title, cause, next step, both buttons), the picker's manual-entry
    field, and two Settings rows. The error page is the one worth a look:
    it is a plain `VStack` (`BrowserView.swift`), the shape F11 had to move
    into a `ScrollView` for the gate. Not fixed here: it changes F4's
    screen, and wants its own measurement at AccessibilityXXXL first.

## 9. Log

Opened 2026-09-24, from Olof's observation that F9 should not have needed his
eyes.

### 2026-09-24 — §4.2 landed, red first

`app/scripts/test-fixture-parity.swift`, in `make test-policy`. It reads the
fake's `PAGE` literal and the installed `index.html` **plus the stylesheets it
links**: the product's `index.html` mentions `env()` only inside an HTML
comment, and its 25 CSS uses live in `assets/src-*.css`, so a check on
`index.html` alone would have been fooled either way. Against the old fake:

```
  real: viewport "width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no, interactive-widget=resizes-content, viewport-fit=cover", 25 env(safe-area-inset-*) in its CSS
  fake: viewport "width=device-width", 0 env(safe-area-inset-*) in its CSS
  FAIL: viewport-fit: product cover, fake (absent) -- the fake must ask for the same layout the product does
  FAIL: interactive-widget: product resizes-content, fake (absent) -- it decides what the keyboard does to the layout viewport
  FAIL: env(safe-area-inset-*): product uses it 25x, fake 0x -- the fake must consume the insets the way the product does
fixture-parity: 3 FAILED
```

The fake now carries the product's viewport verbatim and pads its body by
`env(safe-area-inset-*)`. No existing L1 test moved (14/14, 210 s). F9 §6's
probes landed alongside; their first measurement is in F9 §9.

### 2026-09-27 — §4.3–4.5 built

**§4.3.** A fourth probe, `window-safe-insets`, reads the window's four
insets (portrait: 62/0/34/0; landscape: 0/62/20/62 on the iPhone 17).
The first run named one element: Settings' Done at x = 42 in landscape,
against a 62 pt left inset. It is a plain `.cancellationAction` toolbar
item; the system places bar items in the side band beside the island's
column, so bar items are held to the top and bottom only. With that, every
flow swept clean in both orientations. Shown to fail with
`.ignoresSafeArea()` on the gate's container:

```
gate portrait: login-button (16.0, 811.7, 370.0, 50.3) reaches the bottom unsafe region; safe area (0.0, 62.0, 402.0, 778.0)
gate landscape: login-button (16.0, 339.7, 842.0, 50.3) reaches the left+right+bottom unsafe region; safe area (62.0, 0.0, 750.0, 382.0)
```

**§4.4.** `.clippedText` is spelled `.textClipped`. The first attempt
suppressed findings "inside the web view's frame", which suppressed
everything: the web view stays in the tree, full screen, under the error
page and every sheet. An element is now the page's only when its label and
frame are one of the web view's descendants'. What was left is §8's
baseline. Shown to fail by holding "What happens next" to 60 pt on one
line: `Text clipped: 48 What happens next (16.0, 320.0, 57.0, 20.3)`, both
orientations.

**§4.5, and why it is not the accessibility tree.** Built first as §4.5
described it, from the web view's accessibility snapshot. On the real bundle
it reported collisions the screenshots showed were not drawn: the
list-failed chip and "Ask the agent", scrolled out of the instance bar
(F5's fix clips that row), over the search and status buttons; and in
landscape the hero heading "What can I do for you?" under the session
title. The tree has no clipping and no z-order for web content, and
XCUITest's `isHittable` said "on top" for every one of them, so it cannot
tell drawn from hidden.

So the page is asked (`PageSweep.swift`). Two more things the screenshots
forced: the hero is not covered by anything that takes the pointer — the
stack at the overlap was all transparent, static `div`s — but by a fade
overlay with `pointer-events: none`, which `elementFromPoint` looks
straight through. The sweep therefore forces `pointer-events` on for the
length of the script and treats as covering only what paints a background
colour or image. And one report can land mid-transition, so the test reads
two agreeing reports per orientation. Then: 34 drawn items in portrait, 35
in landscape, no collisions.

Criterion 4, with `installChipRowStyle` returning before it adds the style:

```
portrait: "Switch instance" (128,9 24x24) and "Ask the agent" (131,12 42x19) collide
```

and F5's own test failed alongside it, as it should. Tests on the final
code: the five L1 tests carrying §4.3/§4.4 passed, and the five session
tests sharing the signed-in run passed (`ONLY_TESTS`, instance 7).

