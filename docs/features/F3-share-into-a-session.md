# F3 — Share a link from another app into a session on a gateway

| | |
|---|---|
| **Status** | researched; design below, awaiting Olof's answers to §6 before building |
| **Requested** | 2026-09-23, by Olof: "I want to be able to share from one app straight into a session on kiro to a remote gateway. The by far most common would be for me to want to share a link article straight to the obsidian session on chonk, but the feature should be generic. Share -> latchkey -> gateway/session UI flow. Map out feasability, explore options and present me with well-researched options if needed." |
| **Revision** | will need one: it adds a second target and a new user-facing flow |
| **Touches** | a new share extension or App Intent target, `App/Session`, `App/Discovery`, the project file, and a new end-to-end suite |

## 1. Why

The phone is where links arrive and the crew is where they should land.
Today getting an article into a session means opening Latchkey, finding the
session, and pasting by hand. The flow should be: share sheet → Latchkey →
choose gateway and session → done.

## 2. What is being researched

Two strands, both running as research before any design is written, because
the answers decide the shape of the whole feature.

**The gateway side** — does KiroCrew 0.6.x let a client do this at all?
1. Is there an endpoint that lists sessions (id, title, folder, last activity)?
2. What exactly posts a message into an existing session: HTTP, or a WebSocket
   frame? Body schema, headers, `Origin` enforcement.
3. Can a client create a session, and choose its folder or crew?
4. Attachments versus plain text, and any size limit.
5. Which credential is required, and is any of it bound to loopback rather
   than reachable through `tailscale serve`?
6. Is there anything in the built dashboard bundle that a `WKUserScript` could
   drive instead (and is that honestly less fragile than the API)?
7. Would the gateway refuse an automated post (rate limits, per-session locks,
   the revocation generation)?
8. Is there a deep link that opens a specific session?

**The iOS side** — what is possible for this app, signed by a free personal
team?
1. The current target type for a share-sheet action on iOS 26 / Xcode 27.
2. How a share extension hands a payload to the containing app, and which of
   those routes survive a cold launch: `NSExtensionContext.open`, an App Group
   container, the pasteboard.
3. **Free-team limits**, which may be decisive: can this project add an
   extension target at all, and are App Groups available without paying? Also
   the 10-App-IDs-per-7-days and 3-apps-per-device limits, and whether a second
   target worsens the 7-day expiry ritual.
4. Extension memory and lifetime limits — and confirmation that the extension
   must not run the embedded node (one node, one state directory).
5. Whether an App Intent can receive shared content without a share extension.
6. What comparable apps do: thin capture that opens the host app, versus the
   extension rendering the picker itself.
7. Anything that makes this outright infeasible for a sideloaded, free-team app.

## 3. What is already known

- **The extension cannot use the tailnet.** The embedded node lives in the app
  process with a single state directory; a second process cannot join the same
  node. So the extension captures, and the app — which has the node, the proxy
  and the signed-in dashboard — does the delivery.
- **The app can already act on the dashboard's behalf.** `DashboardSignOut`
  performs a page-world `POST /api/auth/logout` inside the loaded WKWebView
  (R32), reusing the session's own cookies with no credential extraction. The
  same route is the obvious candidate for posting a shared link.
- **The app can also make its own HTTPS requests through the tunnel:**
  discovery probes gateways with an ephemeral `URLSession` built from the
  published proxy configuration. That is the alternative to driving the page.
- **Multiple gateways are now normal** (byskebox, box, chonk), so "which
  gateway" is a real question in the flow, not a formality.
- **ATS stays on and D1 holds:** HTTPS only, and nothing about this may send
  logs or content anywhere but the owner's own gateway.

## 3a. What the research found

### The gateway will take a message over HTTP

All references are into the installed 0.6.0 at
`~/.kiro/crew-venv/lib/python3.12/site-packages/kiro_crew/`.

- **List sessions:** `GET /api/chat/slots` (`dashboard/routes/chat.py:50` →
  `chat_handlers.py:1066`) returns an array of slots with `key`, `title`,
  `folder_id`, `agent`, `running`, `queue_depth`, `last_activity_ts`,
  `last_message`. No paging. Folders: `GET /api/chat/folders`. Archived
  sessions live behind `GET /api/sessions` and must be resumed before they can
  take a message.
- **Send:** `POST /api/chat?ws=1` with `{"message": "<text>", "slot": "<key>"}`
  (`chat_handlers.py:212`). `?ws=1` returns `{"ok":true,"slot":…,"mid":…}`
  at once and the turn streams over the page's own WebSocket; without it the
  response is an SSE stream held open for the whole turn. A busy slot **queues**
  (`{"ok":true,"queued":true}`) rather than refusing. No length cap found. There
  is no client "send" frame on the WebSocket at all — HTTP is the only route.
- **Create:** `POST /api/chat/slots` with optional `name`, `agent`,
  `folder_id`, `title`, `memory_mode`.
- **A trap:** an unknown `slot` is **silently created**
  (`chat_handlers.py:313`, `get_or_create_slot`). A typo makes a new session
  rather than an error, so the app must post only keys it has just listed.
- **Auth is the dashboard cookie** (`mc_token_<port>`); there is no bearer
  token. Non-GET requests are CSRF-checked against the origin allowlist.
- **Deep link:** `https://<gateway>/chat?sid=<slotKey>` selects a session, and
  `&prefill=<text>` drops text into that slot's composer for 30 s without
  sending. Whether a URL alone can auto-send is not confirmed.
- **Driving the page's UI instead is the worst option.** The bundle exposes only
  `window.__mc_chat_launch` (which forces a *new* session) and an
  `mc-widget-send` event that merely fills the composer; the composer has no
  stable test id, and it is React.

**Consequence:** the app should call the API **in the page world of its own
WebView**, exactly as `DashboardSignOut` already posts `/api/auth/logout`
(R32) via `PageScriptSources`/`callAsyncJavaScript`. That carries the session's
cookies and a correct `Origin` with no credential extraction, and works today on
443.

**This feature depends on F1 §4a.** On a gateway served on 8443 the origin
allowlist does not match the ported origin, so every POST — including this one —
returns 403. Sharing to an 8443 gateway cannot work until that is resolved.

### iOS will not let the extension do the sending

- A **share extension** is still the only way into the share sheet's app row
  (`NSExtensionPointIdentifier = com.apple.share-services`); App Intents have no
  share-sheet surface on iOS 26. A user-made Shortcut with "Show in Share Sheet"
  is the extension-free alternative and appears in the actions list, not the app
  row.
- **The extension must never dial the tailnet.** Not mainly for memory (the
  observed hard limit is ~120 MB) but because a node is one key and one state
  directory: a second node would need its own tailnet-lock signature, its own
  grant, and — since `pin_scope: node` — its own sign-in at every gateway. The
  extension captures; the app sends.
- **There is no supported way for a share extension to launch its containing
  app.** `NSExtensionContext.open` is documented for Today and iMessage
  extensions only, and Apple has said so directly on the forums. The
  responder-chain trick works today and is unsupported. The sanctioned bounce is
  a local notification, or the owner opening the app.
- **App Groups are available on the free personal team** on iOS (Apple's
  capability table), so the extension can hand the payload over properly.
  Keychain sharing is available too, as a fallback. TestFlight, Associated
  Domains and Network Extensions are not — none is needed.
- Cost of a second target: a second bundle id and a second 7-day profile minted
  in the same build, so no extra reinstall cadence. The **first** install after
  adding the extension has to go through Xcode's Run, because xcodebuild here
  has no usable Apple ID (DECISIONS 2026-09-23).

## 4. Design: two stages, one app-side flow

The app-side half is the same in both stages and is where the work is.

**Stage 1 — the flow, reachable without a new target.**
- A URL scheme `latchkey://share?url=…&text=…` (`CFBundleURLTypes`, now an
  `INFOPLIST_KEY_` since Xcode rewrote the plist) handled in
  `LatchkeyApp.swift` via `.onOpenURL`, plus an `AppIntent` (`SendLinkIntent`,
  `supportedModes = [.foreground(.immediate)]`) so a Shortcut can drive it.
- `App/Share/ShareInbox.swift`: the pending item (`url`, `title`, optional
  note, timestamp), persisted so a cold launch does not lose it.
- `App/Share/ShareDestinationView.swift`: pick a **gateway** (the existing
  discovery/saved list) and then a **session**, listed with
  `GET /api/chat/slots` through the page world, newest activity first, with the
  folder shown. A gateway that is not signed in says so and offers Sign in
  rather than an empty list.
- Send: `POST /api/chat?ws=1` in the page world with the message text, only
  ever with a `slot` taken from the list just fetched. Then navigate the web
  view to `/chat?sid=<key>` so the owner watches it arrive.
- Result: sent, queued (`queued:true` — say so, it is not an error), or failed
  with the reason and a Retry. Never a silent success.

**Stage 2 — the share sheet proper.**
- A `ShareExtension` target (`net.lixom.latchkey.share`), `NSExtensionActivationSupportsWebURLWithMaxCount = 1` plus text, an `SLComposeServiceViewController` with a link preview and an optional note.
- It writes the item to an App Group container
  (`group.net.lixom.latchkey`), then tries the unsupported open as a courtesy,
  and always schedules a local notification ("Link ready — pick a session") so
  there is a sanctioned way back. The app drains the inbox on `.active` and on
  `onOpenURL`.
- A later refinement (not stage 2): let the extension preselect a destination
  from a list the app cached, once it is known whether a cached list is
  meaningful.

**Fallback kept in reserve:** `/chat?sid=<key>&prefill=<url>` needs no API call
and gives a "review before send" mode. Worth wiring as the behaviour when the
POST is refused (for example on an 8443 gateway before F1 §4a is fixed).

## 5. End-to-end tests

The fake gateway (`testing/harness/fake_gateway.py`) grows the two endpoints
with the real shapes: `GET /api/chat/slots` returning a fixed set of slots, and
`POST /api/chat` recording what it received. Server-side evidence, as in every
other suite here.

| Test | Suite | Asserts | Shown to fail by |
|---|---|---|---|
| A shared link reaches the chosen session | session (M4) | `XCUIDevice.shared.system.open("latchkey://share?url=…")` → picker → pick gateway and session → the fake gateway's journal holds `POST /api/chat` with that URL and that `slot` | posting without a slot (the fake must reject an unknown key) |
| The session list is the gateway's, newest first | session (M4) | the picker's rows match `/api/chat/slots`, ordered by `last_activity_ts`, folder shown | serving a different order from the fake |
| Only a listed slot is ever posted | session (M4) | with the fake returning a slot list that omits the saved default, the app re-lists rather than posting a stale key (the fake 404s an unlisted key and the test asserts no such request was made) | posting the remembered key blindly — the trap in `get_or_create_slot` |
| A busy slot reports "queued", not success | session (M4) | fake returns `{"ok":true,"queued":true}` → the UI says queued | treating `queued` as sent |
| A refused post surfaces, with the prefill fallback offered | session (M4) | fake returns 403 for the POST (the 8443 origin case) → the app says so and offers to open the session with the link prefilled | swallowing the 403 |
| A cold launch does not lose the link | session (M4) | terminate the app, open the share URL, relaunch: the inbox still holds it and the picker appears | keeping the inbox in memory only |
| The share sheet route works (stage 2) | new share suite | drive Safari to the fake dashboard, Share → "Latchkey" → Post → the app is frontmost with the link; then the same journal assertion | building without the extension: the app is absent from the sheet |

XCUITest cannot attach to the extension's process, but its UI appears in
Safari's element tree, which is all the test needs.

## 6. Decisions needed from Olof (my recommendations)

1. **Default destination.** Recommend: remember the last gateway+session and
   preselect it, with the picker still shown so one tap changes it. It makes the
   common case (chonk's Obsidian session) fast without hiding where the link is
   going. *Alternative: always ask with nothing preselected.*
2. **New sessions.** Recommend: not in stage 1. Sharing adds to a session that
   exists; creating one is a second decision (agent, folder, title) that belongs
   in the app proper. `POST /api/chat/slots` is there when wanted.
3. **What arrives.** Recommend: the page title and the URL on one line, plus the
   note if typed — the note field costs nothing in the compose sheet and is
   where "read this, then summarise" goes.

## 7. Open questions and owner actions

Answered in §6 as recommendations; Olof's call.

Owner actions this will need:
- the **first** install after the extension target exists must go through
  Xcode's Run, to mint the second profile (xcodebuild here has no usable Apple
  ID);
- allow notifications once, so the sanctioned bounce works;
- for any gateway on 8443: fix the origin allowlist first (F1 §4a), or sharing
  there returns 403.

## 5. Log

- 2026-09-23: requested; two research strands (gateway API, iOS platform),
  both reported the same day. Design written as two stages. Two findings
  changed the shape: the extension can never send (one node, one state
  directory, and `pin_scope: node`), and there is no supported way for a share
  extension to launch its containing app — so a local notification is the
  bounce and the app drains an inbox. A third finding went into F1 §4a: the
  gateway's origin allowlist is port-blind, so 8443 breaks every POST.
