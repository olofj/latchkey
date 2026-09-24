# F9 — The page gets the real safe-area insets

| | |
|---|---|
| **Status** | **diagnosis reopened** — §1's mechanism was measured and is false. Do not build §4. See §9 |
| **Requested** | 2026-09-24, by Olof, from the first TestFlight install on his iPhone 14: "the page doesn't render well on my iPhone 14, it bleeds too high into the island" (screenshot attached to the request) |
| **Revision** | none — this restores documented behaviour rather than changing it |
| **Touches** | `app/App/Browser/BrowserView.swift`, `app/App/Browser/RawWebView.swift`, `testing/harness/dashboard.py`, `scripts/test-offline.sh` |

## 1. Why

On the first real-device install, the dashboard's own top bar renders *under*
the status bar and the Dynamic Island: its icons and unread badge sit behind the
island, and the page's first line of text is clipped by it.

The page is not at fault, and this is the part worth having measured before
touching anything. The shipped KiroCrew frontend both opts into edge-to-edge
layout **and** compensates for it:

```
$ grep -n 'name="viewport"' .../kiro_crew/static/dist/index.html
29:  <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1,
     user-scalable=no, interactive-widget=resizes-content, viewport-fit=cover" />

$ grep -roh 'env(safe-area-inset-[a-z]*[^)]*)' .../kiro_crew/static/dist | sort | uniq -c
  17 env(safe-area-inset-top)
  16 env(safe-area-inset-bottom)
  12 env(safe-area-inset-left)
   9 env(safe-area-inset-right)
```

(Read from the installed 0.6.0 package, not run.) So the page asks for the full
rect and then insets its own chrome by `env(safe-area-inset-top)`. It renders at
the very top only if it is being told that inset is **zero**.

Which is what we tell it. `BrowserView.swift:40` applies
`.ignoresSafeArea(.container, edges: .top)` to the web view, and SwiftUI's
`ignoresSafeArea` does not merely extend a view under the island — it zeroes the
safe-area insets propagated into that subtree. `WKWebView.safeAreaInsets.top`
becomes 0, WebKit computes `env(safe-area-inset-top)` from it, and the page
faithfully draws its header at y=0.

The comment at `BrowserViewModel.swift:302` — "Keep UIKit's default automatic
adjustment. With the WKWebView laid out beneath the notch, WebKit can then
distinguish ordinary pages … from viewport-fit=cover pages" — describes a UIKit
view laid out under the notch with its insets intact. It does not hold once
SwiftUI has zeroed them, and nothing measured that it still held.

The same reasoning applies at the bottom, where `DashboardRootView.swift:216`
ignores the bottom container edge and the page uses `env(safe-area-inset-bottom)`
16 times, and at the sides in landscape.

**To confirm before building** (task 1 below): log `WKWebView.safeAreaInsets` at
first layout on a Dynamic Island device and show it is `0` at the top. If it is
already non-zero, this diagnosis is wrong and the spec must be rewritten rather
than worked around.

## 2. What the owner sees

Working: the dashboard's top bar sits wholly below the Dynamic Island, and its
bottom bar above the home indicator, exactly as it does in Safari on the same
phone. Page background still runs to all four physical edges, and content
scrolling beneath the status bar keeps the soft edge feathering
(`scrollView.topEdgeEffect.style = .soft`) that only makes sense when content
really does pass under it.

Failing: there is no new failure mode. If the insets cannot be determined, the
web view is laid out with the system's own safe area — content is never *more*
hidden than it is today.

## 3. Non-goals

- **Not** injecting CSS into the dashboard to reposition its header. It works
  correctly given correct insets; patching another product's DOM would couple us
  to its internals, which we only do for the documented manifest literal.
- **Not** abandoning edge-to-edge by dropping `.ignoresSafeArea` outright. That
  would fix the clipping by letterboxing the page inside a band of app
  background — correct but a visible downgrade, and it would make the soft edge
  effect pointless. Kept as the fallback if §4's approach cannot be made exact.
- **Not** changing `contentInsetAdjustmentBehavior`. Automatic adjustment is what
  gives *ordinary* (non-cover) pages their inset viewport, and test 2 pins it.

## 4. Design

The web view stays full-bleed; the insets it reports become true again.

1. **`BrowserView.swift`** — measure the real insets *outside* the ignoring
   subtree and pass them down. A `GeometryReader` placed around the `ZStack`
   reports `proxy.safeAreaInsets` before `.ignoresSafeArea` is applied to the
   child; that value is the window's.

2. **`RawWebView.swift`** — take `safeAreaInsets: EdgeInsets` and, in
   `updateUIView`, set
   `webView.additionalSafeAreaInsets = UIEdgeInsets(top:left:bottom:right:)`
   from it. Because SwiftUI zeroed the view's own insets, "additional" and
   "total" coincide; this is the one place that assumption is load-bearing, so
   test 1 asserts the total the *page* sees rather than what we set.

3. Set it on every `updateUIView`, not once at `makeUIView`: the value changes on
   rotation and on a scene entering a different geometry (Stage Manager, split
   view). No new state.

4. Leading/trailing insets are injected too. In landscape the island takes a side
   inset, and the page uses `env(safe-area-inset-left/right)` 21 times between
   them.

**Invariants this must not break** (see `../../app/AGENTS.md`): the split tunnel
still decides what goes through the proxy; `allowFailover` stays false; ATS stays
on with no exceptions; D1 — no app or node logs leave the device; a vendored-tree
change would be its own commit (this touches none).

## 5. State and migration

Nothing is persisted. The insets are derived from the scene's geometry on every
layout pass; there is no stored value and nothing a previous version wrote.

## 6. End-to-end tests

Both in L1 (`scripts/test-offline.sh`), which already runs the real app and a
real `WKWebView` against the fake dashboard, and needs no tailnet. The evidence
is server-side: the page reports what it was given, and the harness records it,
rather than a test reading pixels off the screen.

Harness change (`testing/harness/dashboard.py`): serve two probe pages that
report their computed insets and viewport to the control port, recorded in
`/__state`:

- `/__inset-cover` — `<meta name=viewport content="width=device-width,
  viewport-fit=cover">`, CSS `:root { --sait: env(safe-area-inset-top); … }`,
  and a script POSTing the four computed values plus `innerHeight`.
- `/__inset-plain` — the same reporter with **no** `viewport-fit`, to pin the
  ordinary-page path.

| Test | Suite | Asserts | Shown to fail by |
|---|---|---|---|
| A cover page is told the real top inset | L1 | `/__state` shows the cover probe reported `safe-area-inset-top` equal to the simulator's own top inset (non-zero; ~59pt on a Dynamic Island device), and `bottom` equal to its home-indicator inset | Reverting `BrowserView.swift` to today's bare `.ignoresSafeArea(.container, edges: .top)`: the probe reports `0px`, which is the reported bug |
| An ordinary page is still inset by WebKit, not twice | L1 | The plain probe reports `safe-area-inset-top` of `0px` **and** an `innerHeight` shorter than the cover probe's by the top + bottom insets — i.e. WebKit inset its viewport once | Setting `contentInsetAdjustmentBehavior = .never`, or adding the inset to the plain page as well: the two heights become equal, so the ordinary page is drawn under the island |

Neither test reads the screen, so neither depends on the dashboard's styling or
on a screenshot diff. Both run on whatever device L1 boots; the first asserts
against the inset that device actually reports, so it does not hard-code 59.

## 7. Acceptance criteria

1. On a Dynamic Island device, the cover probe reports a top inset equal to the
   device's — instrument: the harness's `/__state` journal, asserted by test A.
2. The ordinary probe's viewport is shorter by exactly the safe area, and its own
   `env(safe-area-inset-top)` is 0 — instrument: the same journal, test B.
3. `make test-policy` and L1 stay green; no other suite changes behaviour.
4. On Olof's iPhone 14, the dashboard's top bar is fully clear of the island —
   instrument: his eyes, on the next TestFlight build. This one is the report
   that opened the spec, and it is the only criterion a test cannot stand in for.

## 8. Open questions and owner actions

- **Is the diagnosis right?** §1's confirmation step gates the rest. If
  `safeAreaInsets.top` is already non-zero at first layout, the cause is
  elsewhere — most likely WebKit's own handling of `interactive-widget=
  resizes-content`, which the dashboard also sets and which this spec has not
  examined.
- **Owner action:** none until a build exists. Then: install the TestFlight
  build and confirm criterion 4, in portrait and landscape.
- **Corrected 2026-09-24.** This said "the iPhone 14 has a Dynamic Island". It
  does not: the plain 14 has a notch (~47pt) and only the 14 Pro has the island.
  Olof confirmed he is on a **14 Pro** (59pt), so L1's `iPhone 17` simulator
  (62pt measured) is representative in kind, differing only in magnitude. Had he
  been on a plain 14, the simulator would have been reproducing different
  geometry from the bug report — which is why the question was worth asking
  rather than assuming from the model name.

## 9. Log

Opened 2026-09-24 from the first TestFlight install.

### 2026-09-24 — the confirmation step ran, and §1 is false

§8 made the measurement a gate. It was right to. From 42 `safe-area:` lines in
`app/build/offline-logs/20260924-135534/unified.log`, steady state:

| | WKWebView's own | The window's | The GeometryReader's |
|---|---|---|---|
| top | **62** | 62 | 62 |
| bottom | 0 | 34 | 34 |

**`.ignoresSafeArea(.container, edges: .top)` does not zero the insets.** UIKit
hands WebKit a correct 62pt top inset. The mechanism in §1 — SwiftUI zeroing the
subtree, WebKit computing `env(safe-area-inset-top)` from a zero — is disproved
on the one edge the bug report is about.

**§4 would have made it worse.** The prediction was that the GeometryReader would
report 0; it reports 62, the same as the view. Feeding that into
`additionalSafeAreaInsets` adds a correct inset to a correct inset: 124pt, half
the page pushed off the bottom. It would have "fixed" the screenshot by
overcorrecting and passed any test that only asserted "not zero".

**A separate finding, not the reported bug.** The web view reports a bottom inset
of 0 while the window reports 34, and `BrowserView`'s slot ends 34pt above the
screen edge — so the web view never reaches under the home indicator.
`DashboardRootView.swift:213` says "The page owns the full screen, including the
bottom safe area". That is false as measured. It needs its own spec.

### What to measure next, and the dependency it exposes

UIKit is telling WebKit the truth, so the next question is what the **page** is
told: its computed `env(safe-area-inset-top)`. That is exactly test A's probe
(§6). Two outcomes:

- **reads 62** — the fault is above UIKit: the page's own CSS, or
  `interactive-widget=resizes-content`, which the real frontend sets and this
  spec has never examined.
- **reads 0 despite the 62pt view inset** — the likely cause is WebKit's
  automatic content-inset adjustment, which §3 currently rules out of scope. The
  spec would have to change rather than be worked around.

**This makes F10 a prerequisite for F9, discovered by measurement rather than
argument.** L1 cannot reproduce the bug today: the fake dashboard's viewport tag
is `width=device-width` (`testing/harness/dashboard.py:89`), so it never asks for
edge-to-edge and can never be clipped by an island. F10 §4.2's fixture parity —
the fake must be no more forgiving than the product — has to land before the next
measurement means anything.
