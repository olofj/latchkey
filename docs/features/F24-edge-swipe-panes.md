# F24 — Edge swipes open the dashboard's drawers

| | |
|---|---|
| **Status** | prototype built 2026-10-08; refined from device feedback the same day (§7); device check owed (§6) |
| **Requested** | 2026-10-08, by Olof: swipe in from the left edge opens the dashboard's left pane (sessions), from the right edge its right pane |
| **Revision** | none: no documented behaviour changes |
| **Touches** | App/Browser (`EdgeSwipe.swift`, `BrowserViewModel.openPane`, `PageScriptSources.edgeSwipeOpenPane`), the L1 fake dashboard |

Citations are to KiroCrew's `static/dist/assets/App-e17PGpKz.js`. That
one file ships in both the installed 0.7.2 and the suite's pinned 0.7.1
wheel.

## 1. Why

At phone width the dashboard already has a drawer swipe (`Jw(...)`, two
uses on the chat page). A rightward drag opens the sessions drawer, a
leftward drag the activity drawer, and the opposite drag closes it. But
while a drawer is closed it ignores any touch that starts within
`Aw=24` px of either edge (`if(e<Aw||e>window.innerWidth-Aw)return`).
That strip is left to Safari's back gesture. Latchkey's web view has no
back gesture (`allowsBackForwardNavigationGestures` is off), so a swipe
from the very edge did nothing. That is where a thumb naturally starts.

## 2. What the owner sees

Swipe in from the left edge: the sessions drawer opens, as if he had
tapped the header's sessions toggle. Swipe in from the right edge: the
activity drawer (browser, changes, files) opens. A swipe that starts
anywhere else is the dashboard's own, unchanged. Closing is the
dashboard's own: the opposite drag, the backdrop, or the close button.
F24 adds no closing gesture.

Nothing happens, logged as `edge-swipe: <side> -> <status>`, when:
the page is not the chat page (`no-control`); a dialog is up, or for
the right edge the sessions drawer is open (`blocked`); the drawer is already open
(`already-open`); or the page is off the gateway's origin
(`off-gateway`).

## 3. Non-goals

No closing gesture. No change to the page's own swipe. No iPad
behaviour of its own (§5).

## 4. Design

- `EdgeSwipe` adds two `UIScreenEdgePanGestureRecognizer`s (`.left`,
  `.right`) to the web view and calls back at most once per gesture,
  after 40 pt of mostly horizontal inward travel or on a flick (§7). They
  recognise alongside WebKit's recognisers but not alongside scroll
  views, whose pans wait for theirs to fail (§7). A screen-edge
  recogniser only starts on a touch that begins at the edge, so a
  horizontal scroll inside the page never reaches it. `-UITestNoEdgeSwipe`
  leaves them out.
- `BrowserViewModel.openPane(fromEdge:)` checks that the main frame is on
  `sessionOrigin` (F6). It then runs `edgeSwipeOpenPane` with
  `callAsyncJavaScript` in the `latchkey-edge-swipe` world, which the page
  cannot see, and logs the status the script returns.
- `edgeSwipeOpenPane` uses these hooks, in order of preference:

| Need | Hook in the bundle | Why |
|---|---|---|
| on the chat page | `[data-owns-swipe~=left/right]` | the root the page's own swipe hangs on; not localised |
| right drawer: open | `window` event `toggle-activity-panel` | the dashboard's own API (`addEventListener('toggle-activity-panel', …)`); on a phone it opens the activity drawer |
| right drawer: is open | a shown `button[aria-label="Close panel"]` | no test id; the event toggles, so an open drawer must be left alone |
| left drawer: open | a shown `button[aria-label="Toggle sessions"]`, clicked | no event or test id exists for it |
| left drawer: is open | `[data-testid="sessions-backdrop"]` | rendered only while that drawer is not closed |
| a dialog is up | a shown `[role=dialog]`/`[role=alertdialog]` | the page's own swipe refuses then too |

No class-name selectors are used. The script's click is untrusted, so
F17 does not count it as a tap.

## 5. Risks

- **Locale.** Both `aria-label`s are KiroCrew's English strings
  (`pages.chatPage.toggle_sessions`, `pages.chat.sidePanel.close_panel`).
  The bundle ships at least zh, hi, ko, ru, de, es and it translations.
  Under another locale the left swipe reports `no-control`, and a right
  swipe on an open activity drawer closes it.
- **Dashboard updates.** Any of the hooks can be renamed. The L1 page
  copies them, so it would keep passing. Only the session suite or a
  device would notice. The fix belongs upstream: a
  `toggle-sessions-drawer` event to pair with `toggle-activity-panel`,
  `open`/`close` variants of both instead of toggles, and test ids on
  the two drawers.
- **Landscape.** The web view stops at the side safe areas (F9), so on a
  notched phone it may not touch the screen edge. A screen-edge
  recogniser on it may then never begin.
- **iPad** is untested (F20).

## 6. Tests

- L1 `testEdgeSwipesOpenTheDashboardsDrawers` uses `dashboard.py`'s
  `panes` page, which has the hooks above. It drags in from x = 1 pt and
  from the right edge and expects each drawer to open. Two mid-screen
  drags must open nothing. Shown to fail with `-UITestNoEdgeSwipe`: no
  `toggle-activity-panel` event arrives and the right drawer stays
  closed.
- **Not in the session suite.** The hooks were checked in the pinned
  bundle by search. The existing `testTheSessionsPanelStillOpensInPortrait`
  already finds and taps the real "Toggle sessions" button at phone
  width. No suite drives an edge swipe on the real page.
- **Device check (owed):**
  1. On the chat page, swipe in from the left edge. The sessions drawer opens,
     once the finger is about a thumb's width in, not at the first touch.
  2. Swipe in from the right edge. The activity drawer opens.
  3. A swipe from mid-screen still behaves as before (the dashboard's own).
  4. With a drawer open, the opposite drag still closes it.
  5. In landscape, try both edges (§5).
  6. With a dialog open (e.g. the agent picker), the edges do nothing.
  7. Off the chat page (Settings, Artifacts), the edges do nothing.
  8. Settings → Diagnostics → Logs shows `edge-swipe:` lines with the
     statuses above.
  9. Swipe in from either edge with the thumb drifting up or down. The
     drawer opens and the chat behind it does not scroll.
  10. A brief touch at the edge that barely moves opens nothing.
  11. Ordinary vertical scrolling in the chat, starting near but not at
      the edge, feels as before (no lag before it starts).

## 7. Device feedback, 2026-10-08 (build 202610090422)

1. "The side panels jump out a bit too quickly when swiped. It's a bit
   startling."
2. "It seems that up-down scrolling still happens. ... the background
   doesn't scroll up/down when you swipe in the side panel."

**Scrolling (2).** Cause: the delegate let the edge recognisers run
alongside every other recogniser, including the pan of the chat's inner
scroller. The real shell never scrolls its document (`h-dvh`,
`overflow-hidden`); WebKit backs each overflow scroller with a native
scroll view, so its pan moved the chat with the finger's vertical
drift. Fix: the edge recognisers no longer recognise alongside a
recogniser whose view is a `UIScrollView`, and those pans are required
to wait for the edge recognisers to fail. A touch that does not start at
the edge fails them at once, so ordinary scrolling is not delayed by
design (device item 11 checks the feel). Native only: no page-side
`touch-action` or `preventDefault`.

**Abruptness (1).** Cause: the prototype opened the drawer at `.began`,
a few points into the touch, before the swipe read as deliberate. The
dashboard's own open animation is not the problem: `Gw(Id,0)` in the
sessions drawer's open (`Zd`) animates the panel with the Web Animations
API over `Iw`'s `aoe=.42` s on ease `Nw=[.32,.72,0,1]` (offsets
1840476, 211189, 209144-209255), already calm; under
`prefers-reduced-motion` it is `foe`, 0.12 s linear. So option (b), a
gateway stylesheet lengthening it, would not help and would need a
selector on the panel; option (c), tracking the finger, needs the
page's private motion value. Chosen: option (a). The drawer opens once
the finger has gone 40 pt inward with more horizontal than vertical
travel, or on release after 20 pt at 500 pt/s or more. Direction is
`|dx| > |dy|`, not stricter: the swipe already owns the touch, so a
strict ratio would only make drifting swipes do nothing.

**Tests.** `dashboard.py`'s `panes` page now has an inner scroller, as
the real shell does, and reports its `scrollTop` as `top`. The L1 test
adds: a plain vertical drag scrolls (`top` > 0); right- and left-edge
swipes drifting about 20% of the screen height open their drawers and
leave `top` unchanged; a slow 36 pt nudge at either edge opens nothing.
Before the fix the right-edge swipe moved `top` from 405 to 569 and the
test failed. Two assertions do not discriminate in the simulator: the
prototype's left-edge swipe did not move `top`, and XCUITest's slow
36 pt nudge never began a screen-edge recogniser at all. Both are kept
as guards, and device items 9-10 cover them.

## 8. Device feedback, build 202610090504

Olof, 2026-10-08: "Pretty good now. I wish the pane would move like
when you close it, and not just pop fully open, but that's ok."
Accepted as is. A pane that tracks the finger on open needs the
dashboard to expose its drawer drag offset (kept private today, §7);
it belongs in the upstream request in §5, not in Latchkey.
