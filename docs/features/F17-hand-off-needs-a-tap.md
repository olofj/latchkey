# F17 — Another app opens only from a tap

| | |
|---|---|
| **Status** | spec, 2026-09-25 |
| **Requested** | [issue #2](https://github.com/olofj/latchkey/issues/2), by Olof: "open known-safe schemes (`mailto`, `tel`, `https` universal links) as today, and confirm or refuse everything else. Never open another app from a navigation the user did not start." |
| **Revision** | **R42** (`../PLAN-REVISIONS.md`). R3 said a main-frame navigation off the gateway "leaves the app". F6 (R41) tightened the same invariant for subresources. This is the other half: what leaves, and when, is now decided rather than assumed |
| **Touches** | `App/Browser/NavigationPolicy.swift` (a pure `HandOffPolicy` and `TransientActivation`), `BrowserViewModel` (every hand-off goes through one function, plus the prompt), `PageScripts`/`PageScriptSources` (a trusted-click reporter in its own world), `BrowserView` (the alert), `TabManager` (comment and a result log), the fake dashboard (`handoff` page), L1, the host policy test. `NavigationPolicy.decide`, the rule list, `TSNet/`, and the split tunnel are not changed |

## 1. Why

F6 closed off one way that content rendered by the dashboard could reach past its own origin: fetches. This spec closes the other way, which is handing a URL to another app. The dashboard renders agent output, and that output can be built from pages the owner shared in. So what a link points to is chosen by someone other than the owner.

I checked the issue's diagnosis against `009dbbb`. Two of its three citations hold:

- `NavigationPolicy.swift:74-77`: the `default:` branch returns `.openExternally` for any scheme it does not name. That covers `shortcuts:`, `sms:`, `facetime:`, `itms-services:` and any app's custom scheme.
- `TabManager.swift:185-197`: `openExternally` refuses only `javascript`, `data`, `file`, `blob` and `about`, then calls `UIApplication.shared.open(url)`. It shows no prompt. (The issue cites 180-192.)
- **`BrowserViewModel.swift:987-992` is the wrong place.** That code is `acceptSameDocumentURL`, which filters URL KVO for `pushState`. It is not involved in hand-off. When a script sets `location`, the navigation reaches `decidePolicyFor navigationAction` (`:1138-1160`). That function hands every `.openExternally` URL to the system without checking who started the navigation. `window.open` reaches the same path through `routeNewWindow` (`:1265-1281`), including through `PopupCatcher` when the popup starts blank.

The issue does not mention one more thing, and it shapes the design: **`navigationType` cannot tell a tap from a script.** When a script calls `a.click()`, WebKit reports `.linkActivated`, the same value a real tap gives. A link whose `onclick` sets `location` is a real tap, but WebKit reports `.other`. So the signal has to be a trusted event, and the page must not be able to forge it. F6's marker already uses this idea: a listener in the app's own content world accepts only `isTrusted` clicks.

## 2. What the owner sees

| Link | Tapped | Started by a script, no tap |
|---|---|---|
| another web origin (`http`, `https`), `mailto:`, `tel:` | opens, as today | **asks** |
| any other scheme (`shortcuts:`, `maps:`, `sms:`, an app's own scheme) | **asks** | **refused**, logged, nothing shown |
| `javascript:`, `data:`, `file:`, a foreign `blob:` | refused, as today | refused, as today |
| the gateway's own origin | loads here, as today | loads here, as today |

The prompt is a system alert:

> **Open outside Latchkey?**
>
> `shortcuts://run-shortcut?name=…` (the URL, truncated at 300 characters)
>
> *This opens another app.* — or — *The page asked for this without a tap.*
>
> [ Cancel ]  [ Open ]

**Cancel** is the default action. The app shows only one prompt at a time. While a prompt is up, any further hand-off is refused. After the owner cancels a prompt that no tap started, later untapped requests are refused without a prompt until the next trusted tap. This means a page that has been told no cannot keep asking.

**Why these schemes stay silent.** Opening one of them does nothing irreversible until the owner acts again inside the other app. Safari only shows a page. Mail opens a draft. For `tel:`, iOS asks before it dials. Universal links fall under `https`, as the issue asks. `sms:` also meets this test, since it opens a draft. It is still left out, because the issue named a smaller set and an extra prompt costs one tap. Every other scheme is an unknown app doing an unknown thing, and `shortcuts://run-shortcut` actually runs something.

**Why untapped web links get a prompt instead of a refusal.** "Tapped" means a trusted click within the last second (§4.2). A tapped link can still arrive later than that. For example, a server redirect over a relayed tailnet can take longer than a second, or a click handler can wait on an API call before it navigates. If those were refused, a working link would go dead with no explanation. A prompt keeps them working, and the owner's tap on **Open** is the start the issue asks for.

**Why an untapped custom scheme is refused instead of prompting.** A prompt that no tap caused is exactly how a page would get an owner to run a shortcut: a dialog appears while they are reading, and they tap **Open** out of habit. A legitimate link to another app is always tapped, so nothing that works is lost.

## 3. Non-goals

- **No app names in the prompt.** `canOpenURL` needs every scheme listed in `LSApplicationQueriesSchemes`. The prompt shows the URL instead.
- **No per-scheme allowlist in Settings.**
- **No change to what loads in the view.** `NavigationPolicy.decide` still returns the same result for each of its 25 cases.
- **The piggyback is not closed, and cannot be.** A page script that listens for the owner's clicks can navigate from inside one of them, so its navigation counts as tapped. Every browser has the same limit (HTML's "transient activation"). This is why being tapped does not make an unknown scheme silent. Only the three low-harm schemes are.

## 4. Design

### 4.1 `HandOffPolicy` (pure, in `NavigationPolicy.swift`)

```swift
enum HandOffDecision { case open, ask, refuse }
enum HandOffPolicy {
    static let silentSchemes: Set<String> = ["http", "https", "mailto", "tel"]
    static let neverSchemes: Set<String> = ["javascript", "data", "file", "blob", "about"]
    static func decide(url: URL?, userStarted: Bool, untappedAsksMuted: Bool) -> HandOffDecision
}
```

It encodes §2's table. `NavigationPolicy` still decides *here or not here*. `HandOffPolicy` decides what happens to a URL that is *not here*.

### 4.2 What "the user started it" means

`TransientActivation` (pure, in the same file) holds the time of the last trusted click. `consume(now:)` returns true only if that click is at most **1 s** old, then clears it, so one tap starts at most one hand-off. The value comes from a new script, `PageScriptSources.activationReporter`, which runs in its own world (`latchkey-activation`) in every frame from document start. It adds one capture-phase `click` listener on `window` and posts only when `e.isTrusted`. Only `click` is used: a trusted `click` covers a tap, a keyboard activation and a form's implicit submit, but not scrolling or typing. The handler accepts posts only from frames on the gateway's origin, using the same check as F6's marker (`SessionManager.matches`).

In each place the app hands a URL off, the user-started value is:

| Where | user-started |
|---|---|
| `decidePolicyFor navigationAction` → `.openExternally` | `activation.consume()` |
| `createWebViewWith` (`target=_blank`, `window.open(url)`, and a blank popup's later destination) | `activation.consume()` **when the window is requested**, carried into `PopupCatcher`'s route. KiroCrew's Drive download opens a blank window when you click and sets its location after an API call, which can come seconds later |
| the context menu's *Open* and *Open in Safari*, F6's blocked-image marker | true, because each is a native control or a trusted tap in the app's own world |

### 4.3 One path out

`BrowserViewModel.handOff(_:userStarted:)` is the only caller of `openExternally`. `.open` calls it. `.ask` publishes `pendingHandOff`, and `BrowserView` shows the alert. `.refuse` logs `Hand-off refused (<reason>): <redacted URL>`. `TabManager.openExternally` keeps its refusal list as a last line of defence and now logs when `open` reports failure.

## 5. State and migration

Nothing is persisted. The activation timestamp, the pending prompt and the mute are all in memory and belong to the web view's model.

## 6. End-to-end tests

The fake dashboard gains a `handoff` root page, selected with `/__mode?root=handoff&auto=…`. `auto=app` makes the page set `location` to `maps://` and call `.click()` on a hidden `maps:` link, with no tap, then report `auto: done`. `auto=web` makes the page set `location` to the away origin every 2 s and report each attempt. The page also has a tappable `maps:` link and a button whose `onclick` sets `location` to the away origin.

| Test (L1) | Asserts | Shown to fail by |
|---|---|---|
| `testATappedLinkToAnotherAppAsksFirst` | tap `maps:` → alert. Cancel → Maps is not frontmost 3 s later. Tap again, Open → Maps is frontmost | `009dbbb`: Maps opens with no alert |
| `testAScriptCannotOpenAnotherAppWithoutATap` | once `auto: done` is reported, neither the `location` change nor the synthetic click brought up an alert or Maps | `009dbbb`: Maps opens |
| `testAnUntappedLinkAwayAsksOnlyOnce` | alert, not Safari. Cancel → two more attempts are reported, with no alert and no Safari. The away origin never loads in the app | `009dbbb`: Safari opens. Removing the mute: a second alert |
| `testATapThatNavigatesByScriptStillOpensSafari` | tap the `onclick` button → Safari is frontmost, with no alert | making the activation reporter post nothing: an alert appears |
| existing `testRedirectToAnotherOriginLeaves…`, `testWindowOpenToAnotherOriginStillOpensSafari` | unchanged: tap → Safari, no alert | as above: they would get an alert. This also shows the click message reaches the app before the navigation decision does |

Host (`make test-policy`): the 25 existing checks stay unchanged. New checks cover every cell of §2's table, the mute, the scheme case, and `TransientActivation` (unconsumed, expired at 1 s, consumed once). They are shown able to fail by breaking the policy on purpose (§9).

## 7. Acceptance criteria

- `UIApplication.shared.open` is reached only from `handOff` → `.open`. Instrument: `grep -n "openExternally(" app/App` shows `handOff` as the only caller inside `BrowserViewModel`.
- With no tap, the page cannot bring another app forward (L1, above).
- A tap on a web link opens Safari with no prompt, as before (L1, three tests).
- All 25 R3 checks pass unchanged. L1 is fully green.

## 8. Open questions and owner actions

- **Olof:** should `sms:` join the silent set? It is left out for now (§2).
- On the device: whether a universal link to an installed app still opens with no prompt. It should, because the scheme is `https`. The simulator has no universal-link apps to show it.

## 9. Log
