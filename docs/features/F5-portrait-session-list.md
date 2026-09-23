# F5 — The instance chips collide in portrait

| | |
|---|---|
| **Status** | **measured 2026-09-23 — the original diagnosis was wrong; options re-framed, needs Olof's call again** |
| **Requested** | 2026-09-23, by Olof (bug report): "the list of remotes on the top left isn't really visible on portrait mode phone. Works well on landscape. Not sure if it's fixable since it comes from the dashboard but it affects user experience." |
| **Revision** | depends on the option: C would need one (it adds app UI over the page) |
| **Touches** | `App/Browser` (page scripts or a native affordance), possibly `App/Session`; the session suite |
| **Tracker** | would be issue #1 once the private repos exist; this document is the record until then |

## 1. What is actually wrong (measured, not inferred)

The first spec guessed from the bundle's CSS that the dashboard's **session
sidebar** needs 768 px and so is unreachable at 393 px. **That guess was
wrong.** Driving the real KiroCrew 0.6.0 bundle through the fake gateway on a
402 pt-wide simulator, in both orientations, shows something narrower and more
specific.

**The sessions panel is fine in portrait.** Tapping *Toggle sessions* opens a
proper full-height overlay — header, search field, New button, list, "Older
Sessions" — entirely usable at 402 pt.
![The sessions panel in portrait](f5-measurement/portrait-sessions-panel-works.png)

**The instance chips are what collide.** The row at the top-left — `Local`, a
remote instance (`⚠ not found` in the harness), `Ask the agent` — overflows its
width in portrait and the labels are drawn **on top of each other**, unreadable:
![The chips overlapping in portrait](f5-measurement/portrait-chips-overlap.png)

The same three chips in landscape (874 pt), laid out cleanly, so it is the
width and nothing else. (The screenshot is stored as the device produced it,
rotated.)
![The same chips in landscape](f5-measurement/landscape-chips-ok.png)

So Olof's words were exact: *"the list of remotes on the top left isn't really
visible on portrait mode phone"*. It is the **instance/remote switcher**, not
the session list, and it is an overflowing flex row rather than a hidden
sidebar.

Measured facts, for whoever builds this:
- portrait window 402 × 874 pt, landscape 874 × 402 pt;
- the controls are real accessibility elements in both orientations:
  `Toggle sessions` (36 × 36), `Open menu` (40 × 40), `Switch instance`
  (25 × 24) — so the app **can** drive them, and a test can find them;
- `Switch instance` sits at x = 127 in portrait, inside the colliding row.

## 2. What this invalidates

- **The Tailwind-breakpoint theory** (§1 of the previous draft): the 640/768
  bands are real in the bundle but are not what breaks here, and the 861 px
  rules are Excalidraw's. Deleted rather than left to mislead.
- **The decision of 2026-09-23** — "a native session switcher behind the gear" —
  was taken on the wrong premise. A *session* switcher duplicates a panel that
  already works in portrait. What is missing is the **instances** list. The
  choice is therefore back with Olof, re-framed in §3.
- The shared-component argument with F3 survives, but only for the share
  destination picker (F3 needs a session list of its own regardless); it is no
  longer a reason to build a session switcher for F5's sake.

## 3. Options, re-framed around the real bug

**A. Report it upstream (do this regardless).** A chip row whose labels overlap
at 402 pt is a bug in any phone browser, not only in this app, and the
screenshots above are the whole report. Costs nothing, helps every KiroCrew
user on a phone, and is the only fix that lasts without maintenance.

**B. One injected CSS rule, gated to the gateway's origin.** The row is a flex
container that does not wrap; letting it wrap, or scroll horizontally, makes
the chips legible. This is far narrower than the "override the breakpoint" idea
the first draft proposed — it targets one overflowing row.
*Against:* it depends on the bundle's class names, so it can stop applying
silently after an upstream change. Mitigated by a test that fails when it stops
working, and by the fact that failure returns the current behaviour rather than
breaking the page.

**C. Desktop content mode** (`preferredContentMode = .desktop`). Gives the row
the width it wants; shrinks the whole dashboard in portrait. A one-line
experiment worth trying on the phone before committing to B.

**D. A native instance switcher.** The app lists instances itself and switches
between them. **Blocked on a question:** the bundle has remote-instance
management ("Add remote instance", "Configured remote instances"), but whether
there is an HTTP endpoint that lists instances — as `/api/chat/slots` lists
sessions — has not been checked. That check comes first if this is wanted.
Note this is *not* shared with F3: F3 needs a session list, which already works
in portrait.

**E. Nothing in the app.** Rotate the phone. Honest baseline, and what happens
today.

## 4. Recommendation

**A plus B.** File the upstream bug with the screenshots, and carry the
one-rule CSS fix locally until a release includes it — the app should not
wait on someone else's release for a legibility bug on its only screen.
C is worth ten minutes on the phone first, because if it is acceptable it needs
no injection at all. D only if switching instances from the phone turns out to
be something Olof does often.

## 5. End-to-end tests

The session suite drives the **real 0.6.0 bundle** through
`testing/harness/fake_gateway.py`, and `XCUIDevice.shared.orientation` rotates
it. The chips are real accessibility elements with frames, which makes the bug
directly assertable rather than a matter of looking at a screenshot.

| Test | Suite | Asserts | Shown to fail by |
|---|---|---|---|
| The instance chips do not overlap in portrait | session (M4), real bundle | in portrait, each chip element's frame is disjoint from its neighbours' and inside the window | disabling the injected rule: the frames intersect, which is the bug as it stands today |
| Landscape is unchanged | session (M4) | the same chips in landscape keep the frames they have today | a rule that applies at every width |
| The fix is inert elsewhere | L1 offline | the rule is not injected for a page on another origin | dropping the origin gate |
| The sessions panel still works in portrait | session (M4) | *Toggle sessions* opens the panel and lists sessions, at 402 pt | a rule that reflows the panel too |

## 6. Acceptance criteria

- In portrait, every instance chip is legible: frames disjoint, inside the
  window, and each chip hittable.
- Landscape is untouched.
- Nothing is injected on any origin but the chosen gateway's.
- The session suite covers it against the real bundle, and the overlap test
  fails without the fix.

## 7. Open questions and owner actions

- **For Olof, re-asked:** the decision of 2026-09-23 (a native session switcher
  behind the gear) answered the wrong question — the session panel already works
  in portrait. What is wanted instead: legible chips (A + B), or a native
  **instance** switcher (D), or both?
- Is switching instances from the phone something you actually do, or is seeing
  which instance is selected enough?
- Upstream: file the chip-overlap bug with the two screenshots. Second report
  after the fonts one (KiroCrew#13161).

## 8. Log

- 2026-09-23: reported; first diagnosis (session sidebar behind a 768 px
  breakpoint) written from the bundle's CSS.
- 2026-09-23: **measured against the real bundle and the diagnosis was wrong.**
  The sessions panel is fine in portrait; the instance chips overlap. Options
  re-framed, the earlier decision invalidated, screenshots kept in
  `f5-measurement/`. The measurement was a throwaway XCUITest, deleted after
  the run; what it established is above.
