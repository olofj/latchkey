# F6 — The web view loads the gateway and nothing else

| | |
|---|---|
| **Status** | spec |
| **Requested** | 2026-09-23, by Olof: "no URLs or network fetches should be attempted in the built in web browser, they should go to the regular browser on the device. This might already be the case, not sure -- since the whole app is a web surface." |
| **Revision** | will need one: it tightens a documented invariant (R3's "exactly one destination") from navigations to every request |
| **Touches** | `App/Browser` (a new content-rule list, `NavigationPolicy` unchanged), the L1 offline and session suites |

## 1. Why, and what already holds

**Navigations are already handled**, which is the half Olof suspected.
`App/Browser/NavigationPolicy.swift` (R3, finding H2) allows a main-frame
navigation only to the chosen gateway's origin; anything else — another origin,
`mailto:`, `tel:`, an app link — is cancelled here and handed to the system, and
`data:`/`javascript:`/`file:` are refused outright. 25 host checks cover it
(`app/scripts/test-navigation-policy.sh`), and the offline suite drives a real
redirect to another origin and asserts the dashboard is not replaced.

**Subresources are not**, because WebKit never asks. `decidePolicyFor
navigationAction` covers navigations, not the fetches a page makes: fonts,
scripts, images, XHR, `EventSource`, and cross-origin iframes (sub-frames are
deliberately `.allow`ed, so the dashboard's same-origin `/sandbox-doc/` widgets
work).

**What that costs today, measured in the real bundle**
(`kiro_crew/static/dist/index.html`):

```
href="https://fonts.googleapis.com/css2?family=Space+Grotesk…&family=JetBrains+Mono…"
href="https://fonts.gstatic.com" (preconnect)
```

So every dashboard load fetches **Google Fonts** straight to the public
internet, outside the tailnet, from the phone. The split tunnel is working as
designed when it lets that go direct (it is not a tailnet host), but it means:

- Google, and anything watching the phone's network, sees this device loading a
  KiroCrew dashboard, on a schedule that matches the owner's working day;
- the app's one-destination promise is true of the address bar it does not have,
  and not true of the traffic it actually emits.

Agent output can widen this: a remote image in a message, or a YouTube/Vimeo
embed (the bundle knows both), loads from wherever it points.

This is the same class of invariant as `allowFailover = false` and ATS-with-no-
exceptions, and it deserves the same treatment: enforced, and tested by
observing the other end.

## 2. What the owner sees

Working: the dashboard behaves as it does now, with **the system's own fonts**
instead of Space Grotesk and JetBrains Mono. Nothing else changes: chat
streams, widgets render, sign-in works.

A tapped link still opens in Safari, exactly as today.

A remote image in agent output does not appear. What is shown in its place is
the decision in §3 — either nothing, or a small "image not loaded" marker that
can be tapped to open it in Safari.

Failing: if the rule list cannot be compiled or installed, the app **does not
load the page**. A single-origin promise that silently degrades to "everything
allowed" is worse than no promise; the connecting state says so and offers a
retry.

## 3. Non-goals and the one open trade-off

- Not a content blocker in the general sense: one rule, one origin.
- Not a change to sub-frame policy for *same-origin* frames: the dashboard's
  widgets must keep working.
- The app's own network calls are out of scope: discovery probes tailnet hosts
  only, and the node talks to control and DERP. Nothing else exists.

**Remote images in agent output — decided 2026-09-23: a tappable marker.** A
blocked image shows a small marker that hands the URL to Safari when tapped, so
the single-origin promise holds and nothing is more than one tap away. Not
blocked silently (the owner would not know an image was there), and not allowed
through (that reopens exactly the tracking-pixel leak this feature closes).

## 4. Design

**`App/Browser/ContentRules.swift`** (new; `App/`, so no project edit):
- Builds a `WKContentRuleList` JSON from the chosen gateway's host:
  one rule, `{"trigger": {"url-filter": ".*", "unless-domain": ["<gateway
  host>"]}, "action": {"type": "block"}}`, compiled with
  `WKContentRuleListStore.default().compileContentRuleList(forIdentifier:…)`.
  The identifier carries the host so a gateway switch compiles a new list
  rather than reusing a stale one.
- Installed on the `WKWebViewConfiguration`'s `userContentController`
  **before the first load**, and replaced when the gateway changes. A leak on
  the first load would defeat the whole feature, so the load waits for the
  compile (it is milliseconds, and cached by WebKit between launches).
- `about:`, `blob:` and the app's injected scripts are unaffected: a content
  rule list filters network loads, and those are not.

**`App/Browser/BrowserViewModel.swift`**: the load path waits for the installed
list, and treats "no rule list" as a failure rather than proceeding (§2).

**Not touched:** `NavigationPolicy` — it already does its half, and this feature
does not change the rules for navigations. `TailnetProxyPolicy` keeps deciding
what goes through the proxy; blocked requests never reach it.

**Sub-frames:** the rule list blocks cross-origin frames as a side effect, which
is what we want; same-origin ones are untouched.

## 5. State and migration

None persisted. The compiled rule list lives in WebKit's store, keyed by an
identifier that includes the gateway host; a stale entry for an old gateway is
harmless and is replaced on next use.

## 6. End-to-end tests

The L1 offline suite already has the instruments: a fake dashboard, a stub SOCKS
proxy with a journal, and **an "away" origin (`dash.localtest.me`) whose server
counts requests** — the R10 positive control exists precisely to prove that a
direct load to that origin *would* succeed, so an absence of requests means
something.

| Test | Suite | Asserts | Shown to fail by |
|---|---|---|---|
| A page that references another origin makes no request to it | L1 offline | the fake dashboard serves a page with an off-origin `<img>`, `<script>`, a `fetch()` and an iframe; the away origin's request count stays **zero** while the page loads | removing the rule list: the count rises (this is the R10 positive control, reused) |
| The dashboard itself still loads and works | L1 offline + session (M4) | with the rule installed, the page loads over the proxy, the WebSocket opens, reports arrive; against the real 0.6.0 bundle the session reaches a live chat | blocking the gateway's own origin by a bad rule |
| Fonts are blocked without breaking the page | session (M4) | no request reaches a stubbed `fonts.googleapis.com` served by the harness, and the page still renders and streams | listing the font host in `unless-domain` |
| A failed rule install does not load the page | L1 offline | with compilation forced to fail (a test hook), no request reaches the gateway at all | proceeding without the list |
| Navigations still leave the app | L1 offline | the existing redirect-away test keeps passing: the dashboard is not replaced, and the away origin is handed to Safari | folding navigation handling into the rule list |
| A remote image shows the marker, and the marker opens Safari | L1 offline | the marker appears for a blocked image; tapping it hands the URL to the system (asserted through the existing "opened externally" instrument) | blocking silently, if the marker option is chosen |

## 7. Acceptance criteria

- **Zero requests** leave the web view to any origin but the chosen gateway,
  measured at the other end rather than in the app.
- The real KiroCrew dashboard still loads, streams and signs in, with system
  fonts.
- A main-frame navigation elsewhere still opens in Safari.
- If the rule list is missing, nothing loads.
- On the device: Settings → Diagnostics shows no direct (non-proxied)
  connections during a dashboard session.

## 8. Open questions and owner actions

- **Olof:** blocked remote images — nothing, or a tappable marker
  (recommended)?
- Should the app ever offer "allow this origin for this session"? It would be a
  hole with a UI on it; recommend not.
- Worth telling KiroCrew: a self-hosted dashboard that fetches fonts from Google
  is a privacy leak for every deployment, and the fonts could be served from the
  gateway. That is the fix that would help everyone, and it costs them a build
  step.

## 9. Log

- 2026-09-23: requested and specified. Half already held (navigations, R3);
  the gap is subresources, and the live example is Google Fonts in the 0.6.0
  bundle's `index.html`.
- 2026-09-23: licences checked — JetBrains Mono and Space Grotesk are both OFL
  1.1 with **no Reserved Font Name**, and the bundle already self-hosts
  OpenDyslexic (with `OFL.txt`), Assistant and the KaTeX faces, so the upstream
  fix is the build step they already run. KiroCrew's issues searched: no
  existing report (#6578 is their capture browser's egress, #9399 is the import
  map, #8091 is the CJK font precedent). Draft report:
  `../upstream/kirocrew-google-fonts.md`, **filed as KiroCrew#13161**. The
  app still blocks the fetch regardless — a client cannot wait for someone
  else's release, and the block is what makes the promise checkable.
