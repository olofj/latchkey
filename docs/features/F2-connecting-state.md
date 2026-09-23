# F2 — A visible connecting state for a page load in flight

| | |
|---|---|
| **Status** | building |
| **Requested** | 2026-09-23, by Olof: "I entered byskebox manually, screen went blank. Not a great UI experience if it's stuck loading something." |
| **Revision** | none — a gap, not a change of documented behaviour (M8 polish) |
| **Touches** | `App/Browser`, the L1 offline suite |

**Specified in flight.** This one was started from a written brief before the
spec-first rule existed (the same day, an hour earlier). The brief is
reproduced below as the spec so the record is honest; everything after F2
is specified before any code.

## 1. Why

On the first real device run the owner picked a gateway whose tailnet grant was
missing, so the SOCKS dial was dropped by the policy rather than refused. The
node log shows the shape:

```
socks5: dial tcp byskebox…:443 failed: context deadline exceeded
```

WKWebView sat on the main-frame load for tens of seconds with nothing painted —
a blank white screen, no indicator, no text — until WebKit gave up and the
existing error overlay (`nav-error-overlay`) appeared. Nothing told him the app
was still trying, or where to look.

## 2. What the owner sees

Working: while the first load of a gateway is in flight and nothing has
painted, a quiet centred state: an indicator and one line naming the host,
"Connecting to byskebox over your tailnet…". It goes the moment content paints.

Slow: after a few seconds, a second smaller line points at the likely cause and
where to look — a new device may not be allowed to reach this gateway yet, and
Settings → Status shows the node's address.

Failing: the load fails and the error overlay owns the screen, as today.

Not shown: a same-document navigation, a subresource, or the page's own
WebSocket reconnect must never flash it over a working dashboard.

## 3. Non-goals

- No spinner over a page that has painted.
- No tappable control inside the overlay unless taps are verified: a Button at
  opacity < 1 over a WKWebView gets no taps (M8 finding).
- Not a diagnosis. It points at Settings → Status; it does not try to explain
  the tailnet.

## 4. Design

In `App/Browser/DashboardRootView.swift`, `BrowserViewModel.swift` and
`BrowserView.swift`, fitting the existing layering (`ConnectionGateView` for
the pre-connect phase, the error overlay, node banners, expiry warnings)
rather than adding a parallel mechanism.

- A published "main-frame load in flight and nothing painted yet" state on the
  browser view model, derived from the existing navigation callbacks.
- Identifier `page-loading`, and its own identifier for the hint line.
- The hint's delay is a named constant with its reasoning in a comment
  (~6–8 s: past a warm load, short of the SOCKS dial's own failure).
- Reload, gateway switch and the R30 relay retry all show it again.
- VoiceOver reads the state; the indicator is not the only signal; correct in
  dark mode.

## 5. State and migration

None. Nothing persisted.

## 6. End-to-end tests

The L1 offline suite (`scripts/test-offline.sh`) drives the real app and
WKWebView against a stub SOCKS proxy and the fake dashboard, and the stub can
be blackholed or closed through its control port — a dial that never completes,
which is exactly the device failure.

| Test | Suite | Asserts | Shown to fail by |
|---|---|---|---|
| The connecting state appears for a stalled load | L1 offline | `page-loading` visible, naming the host, while the proxy is blackholed | removing the state (it never appears) |
| The hint appears when the wait is long | L1 offline | the hint line appears after the threshold, not before | shortening/removing the threshold |
| A fast load does not leave it on screen | L1 offline | after a normal load, `page-loading` is gone | leaving the flag set on `didCommit` |
| It does not cover a working dashboard | session (M4) | with the real KiroCrew bundle live, `page-loading` is absent during the page's own reconnect and refetches | driving it from subresource loads |

## 7. Acceptance criteria

- A stalled first load shows the connecting state within a second, and the hint
  by the threshold.
- The state is absent on every painted page, including during the page's own
  WebSocket reconnect.
- L1 and the session suite stay green.

## 8. Open questions and owner actions

- The exact wording of the hint is the author's; the owner may want it blunter.
- Should the connecting state ever offer "Choose another gateway"? Only if taps
  are verified over the web view; deferred.

## 9. Log

- 2026-09-23: briefed and built by a Fable agent; spec written from the brief
  the same day when the spec-first rule was set.
