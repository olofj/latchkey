# F9 — The page gets the real safe-area insets

| | |
|---|---|
| **Status** | **decided — build §0.** The web view stops being drawn under the island. §1's mechanism is false, §4 is superseded, and "the frontend's CSS is at fault" was the wrong conclusion from the right measurements — see §0 |
| **Requested** | 2026-09-24, by Olof, from the first TestFlight install on his iPhone 14: "the page doesn't render well on my iPhone 14, it bleeds too high into the island" (screenshot attached to the request) |
| **Revision** | none — this restores documented behaviour rather than changing it |
| **Touches** | `app/App/Browser/BrowserView.swift`, `app/App/Browser/RawWebView.swift`, `testing/harness/dashboard.py`, `scripts/test-offline.sh` |

## 0. The decision, which supersedes §1–§4

**Latchkey stops drawing the web view under the Dynamic Island.** The web view is
laid out inside the top safe area, as it already is at the bottom.

Olof's call, 2026-09-24, on being shown the "it's the frontend's CSS" conclusion:
*"I disagree. It doesn't know it's being rendered on a phone. Don't draw the
webpage at the top of the screen under the island."*

He is right, and the reasoning matters more than the verdict, because the
measurements in §9 were correct and the conclusion drawn from them was not.

**The page's `display-mode` guard is not a bug; it is the page stating its
assumption.** `--safe-area-top` is defined only under `display-mode: standalone`
or `fullscreen` — that is the frontend saying "when I am not an installed web
app, something else is above me, and the inset is not mine to handle." That
assumption is ordinary and widely held. Latchkey is the unusual party: it draws a
page edge to edge with no chrome at all, which is precisely the case the page
told us it does not handle. We then concluded the page was at fault for not
handling it.

**`viewport-fit=cover` looked like consent and is not.** The same stylesheet shows
the page only accepts responsibility for insets as an installed app. Reading the
meta tag as permission to clip it ignores what the CSS next to it says.

**Depending on the gateway's CSS is fragile.** Correct rendering would then vary
with the version each gateway happens to run — sitting badly beside F7, whose
whole premise is that this works on someone else's tailnet. We control Latchkey;
we do not control every deployment of the dashboard.

**The bottom edge already behaves this way.** §9 measured the web view reporting a
bottom inset of 0 while the window reports 34: it already stops short of the home
indicator. This change makes the top consistent with the bottom rather than
introducing a new behaviour.

What this costs, stated plainly so nobody re-litigates it later: the page no
longer bleeds to the physical top edge, and the soft scroll-edge effect
(`scrollView.topEdgeEffect.style = .soft`) has less to feather, since less content
passes under the status bar. That was listed as a reason *not* to do this in §3.
It is outranked by content being unreadable, and §3's bullet is withdrawn.

### 0.1 Design

1. **`app/App/Browser/BrowserView.swift`** — remove
   `.ignoresSafeArea(.container, edges: .top)` from the web view. That is the
   whole functional change: the web view's frame then starts at the safe-area
   top, its own `safeAreaInsets.top` becomes 0, WebKit reports
   `env(safe-area-inset-top)` as 0, and the page draws its header at its own
   y=0 — which is now below the island. The page needs no cooperation, and works
   whatever CSS the gateway ships.

2. **The reclaimed strip must not read as a letterbox.** Tint it with the page's
   own background rather than the app's chrome colour, so the result looks like
   one surface and not a bar above a page. `RawWebView.applyThemeBackground`
   already tracks the colour scheme; `WKWebView.underPageBackgroundColor` (and
   the page's `themeColor` where it has one) is the closer match. If the page's
   colour is unavailable, `Color.platformSystemBackground` is an acceptable
   fallback — it is what shows today before the first paint.

3. **The GeometryReader added during the investigation is not needed** and should
   go with the instrumentation, unless a test wants it. Nothing in this design
   reads the insets: it stops overriding the layout and lets UIKit place the view.

4. **Leave `contentInsetAdjustmentBehavior` alone** (§3 still holds): automatic
   adjustment is what insets ordinary pages, and F10's plain probe pins it.

### 0.2 How it is tested

The probe infrastructure already exists — `/__inset-cover`, `/__inset-plain` and
`/__inset-product` in `testing/harness/dashboard.py`, with
`testInsetProbesReportWhatThePageIsTold` in L1 (commits `f697cfe`, `42647c0`).
The assertions **invert**, and that is the point:

| | before | after |
|---|---|---|
| cover probe's `env(safe-area-inset-top)` | 62px | **0px** |
| the web view's frame `minY` | 0 | **== the window's safe-area top** |

Both are numbers already being collected. A test that asserted "the page is told
62" must become "the page is told 0, because nothing is above it any more" —
rewrite it rather than deleting it, and say so in the commit.

Shown able to fail: restore `.ignoresSafeArea(.container, edges: .top)` and the
cover probe reports 62 again with the frame at y=0.

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
- ~~**Not** abandoning edge-to-edge by dropping `.ignoresSafeArea` outright.~~
  **WITHDRAWN 2026-09-24 — this is now the decision; see §0.** It was ruled out
  here as "a visible downgrade" that would make the soft edge effect pointless.
  That weighed a finish against legibility and got the order wrong. It also
  assumed a letterbox; §0.1 removes that by tinting the reclaimed strip with the
  page's own background, so the result reads as one surface.
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

### 2026-09-24 — the probe ran: the page is told 62

F10 §4.2 landed, and with it §6's two probes (served at `/__inset-cover` and
`/__inset-plain`, and at `/` via `POST /__mode?root=`, because the app loads only
an origin). `testInsetProbesReportWhatThePageIsTold`, L1 on the iPhone 17
simulator, `app/build/offline-logs/20260924-152840/suite.log`:

| probe | top | right | bottom | left | innerHeight |
|---|---|---|---|---|---|
| cover (`viewport-fit=cover`) | **62px** | 0px | 0px | 0px | 840 |
| plain (no `viewport-fit`) | 0px | 0px | 0px | 0px | 778 |

**WebKit passes the truth through.** A cover page is told the real 62pt top
inset; an ordinary page gets a viewport 62pt shorter and `env()` of 0 — WebKit
insets it once, as §6 test B wants. So the fault is not in UIKit or WebKit's
inset plumbing: it is above them, in the real page's CSS or in
`interactive-widget=resizes-content`, which the cover probe does not declare.
The bottom inset of 0 on the cover page is §9's separate finding again (the web
view stops 34pt short of the home indicator), seen now from the page's side.

### 2026-09-24 — the page is told 62 and throws it away

**`interactive-widget` is innocent.** A third probe, `/__inset-product`, carries
the product's complete viewport tag verbatim (`width=device-width,
initial-scale=1, maximum-scale=1, user-scalable=no,
interactive-widget=resizes-content, viewport-fit=cover`). L1,
`app/build/offline-logs/20260924-153956/suite.log`:

| probe | top | right | bottom | left | innerHeight | `kcTop` | display-mode |
|---|---|---|---|---|---|---|---|
| cover | 62px | 0px | 0px | 0px | 840 | **0px** | browser |
| plain | 0px | 0px | 0px | 0px | 778 | 0px | browser |
| product | **62px** | 0px | 0px | 0px | 840 | **0px** | browser |

**The cause is in the frontend's CSS.** The installed frontend is KiroCrew
**0.7.0**, not 0.6.0. It never feeds `env(safe-area-inset-top)` to its top edge
directly. Every top-inset utility (`top-safe`, `top-safe-offset-*`, `p-safe`)
reads `var(--safe-area-top, env(safe-area-inset-top))`, and
`assets/src-BB9Pem3r.css` defines the variable, so the `env()` fallback is dead:

```css
:root{--safe-area-top:0px; …}
@media (display-mode:standalone),(display-mode:fullscreen){:root{--safe-area-top:env(safe-area-inset-top,0px)}}
```

The top inset is honoured only when the page is an installed PWA. In a
`WKWebView`, `display-mode` is `browser`. The probes measured that, and it is
what Safari reports for an ordinary tab, where the browser's own chrome sits
above the page. So the frontend treats the top inset as zero, and its header
sits at y=0 under the Dynamic Island. `kcTop` is that exact rule, copied
verbatim into the probes and measured in the app's own web view: it resolves
to **0px** while `env()` gives **62px** on the same page.

**Latchkey is not at fault. The bug belongs to the KiroCrew frontend's CSS.**
Latchkey hands the page the correct inset, and the page's own rule discards it.
The frontend assumes that "not standalone" means "a browser's chrome is above
me". An edge-to-edge app host breaks that assumption, and so would Safari with
its toolbar collapsed in landscape.

**What was not measured.** The session suite (`scripts/test-session.sh`) serves
the real bundle, but it is pinned to 0.6.0 and refuses 0.7.0: `fake_gateway.py
--check-bundle` fails on the version, on `index.html` and on every pinned auth
file. So the real page's header was **not** measured in a suite: which element
it is, and its `getBoundingClientRect().top`. Re-pinning means re-reading 0.7.0's
auth code (the pin's own instructions), and that is its own piece of work.
0.6.0's CSS is no longer installed, so whether 0.6.0 had the same rule is
unknown. The version the owner's gateway runs is unknown too.

### 2026-09-24 — §0 built: the page is told 0, and the test inverted

`.ignoresSafeArea(.container, edges: .top)` is gone from `BrowserView`. L1 on the
iPhone 17 simulator, `app/build/offline-logs/20260924-165605/suite.log`:

| probe | top | innerHeight | web view `minY` | window safe-area top | strip pixel |
|---|---|---|---|---|---|
| cover | **0px** (was 62px) | 778 (was 840) | **62** (was 0) | 62 | rgb(32, 96, 160) |
| plain | 0px | 778 | 62 | 62 | rgb(32, 96, 160) |
| product | **0px** (was 62px) | 778 (was 840) | 62 | 62 | rgb(32, 96, 160) |

`testInsetProbesReportWhatThePageIsTold` now asserts that every probe is told 0 and
that the web view starts at the window's safe-area top. The expected value
inverted from 62 to 0 because nothing is drawn above the page any more. The
test was not weakened to make it pass. Shown able to fail twice:

- **The top override restored** (`20260924-164216`): `cover: top=62px
  innerHeight=840 webViewMinY=0.0 windowSafeTop=62.0`. The test fails on the
  frame: `0.0 is not equal to 62.0`.
- **The strip forced to the system background** (`20260924-164843`):
  `strip=(255, 255, 255)`. The test fails on the colour.

**The strip's colour.** It is the page's own canvas colour, as computed CSS.
`PageScriptSources.pageBackground` reads it in the app's own content world and
reports it to the app. Two alternatives were rejected. KiroCrew 0.7.0's
`theme-color` is a fixed `#0d0f12`, but the page switches between twenty-odd
dark and light `data-theme`s at runtime, so `theme-color` would paint a dark bar
over a light page. `underPageBackgroundColor` is overridden by `RawWebView` to
stop the pre-paint flash, so reading it returns that override, not the page's
colour. The strip falls back to the system background on the app's own state
pages and until the page reports a colour.

**A regression the layout change caused, and fixed.** The first L1 run after
the change failed both proxy-gone tests on every run: `Details` existed but was
not hittable. SwiftUI orders accessibility siblings by position. The
full-screen state page starts at y=0 and the web view now starts at y=62, so the
web view sorted after the state page and won the accessibility hit test through
it. VoiceOver would have done the same. The web view is now
`accessibilityHidden` while a state page covers it
(`PageState.leavesWebViewUncovered`). This was not an intermittent failure.

L1 passed in 257 s against a 240 s budget, which is 9 s over the 248 s last
measured. The budget is unchanged.
