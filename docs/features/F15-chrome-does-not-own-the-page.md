# F15 — Latchkey does not own the page's corners

| | |
|---|---|
| **Status** | spec — needs a decision in §4 before building |
| **Requested** | 2026-09-24, by Olof, on the first build carrying F9: "I noticed the gear and the notification alarm bell render on top of each other. I don't think latchkey can assume it owns any of the screen to render its own icons on." Plus: "Top bar clears the island. Maybe a bit more than it has to, it could move up a bit." |
| **Revision** | none |
| **Touches** | `app/App/Browser/DashboardRootView.swift`, `app/App/Browser/BrowserView.swift`, the L1 geometry checks (F10 §4.3) |

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
it should not; it starts shown.

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
