# F24 — Edge swipes open the dashboard's drawers

| | |
|---|---|
| **Status** | prototype built 2026-10-08; device check owed (§6) |
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
  `.right`) to the web view and calls back once per gesture, at
  `.began`. They recognise alongside WebKit's recognisers. A screen-edge
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
  1. On the chat page, swipe in from the left edge. The sessions drawer opens.
  2. Swipe in from the right edge. The activity drawer opens.
  3. A swipe from mid-screen still behaves as before (the dashboard's own).
  4. With a drawer open, the opposite drag still closes it.
  5. In landscape, try both edges (§5).
  6. With a dialog open (e.g. the agent picker), the edges do nothing.
  7. Off the chat page (Settings, Artifacts), the edges do nothing.
  8. Settings → Diagnostics → Logs shows `edge-swipe:` lines with the
     statuses above.
