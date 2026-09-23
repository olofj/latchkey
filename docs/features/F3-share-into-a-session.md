# F3 — Share a link from another app into a session on a gateway

| | |
|---|---|
| **Status** | researching — options not yet chosen, nothing built |
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

## 4. Open questions for the owner

- **One gateway or a choice each time?** The common case is one session on
  chonk. Should the share flow remember a default destination and offer to
  change it, or ask every time?
- **New session or existing?** Should sharing be able to start a session, or
  only add to one that exists?
- **What should arrive** — the bare URL, or the title and URL, or a short note
  the owner can type in the share sheet before sending?

## 5. Log

- 2026-09-23: requested; two research strands launched (gateway API, iOS
  platform feasibility). The options and a recommendation land here next, and
  no code is written until this document has a design and tests.
