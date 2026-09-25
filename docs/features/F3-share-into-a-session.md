# F3 — Share a link or a document from another app into a session on a gateway

| | |
|---|---|
| **Status** | built: stage 1 and stage 2. Q1 and Q2 decided by Olof (§8, §9). Owner actions open: the Shortcut, the App Group in Xcode (§8), the device check (§7) |
| **Requested** | 2026-09-23, by Olof: "I want to be able to share from one app straight into a session on kiro to a remote gateway. The by far most common would be for me to want to share a link article straight to the obsidian session on chonk, but the feature should be generic. Share -> latchkey -> gateway/session UI flow. Map out feasability, explore options and present me with well-researched options if needed." Answers of the same day are in §6. |
| **Revision** | needs one: a second entry point into the app (URL scheme, App Intent, optionally a share extension), a new user-facing flow, and the first App Group if stage 2 is built |
| **Touches** | new `App/Share/`, `App/Browser/PageScriptSources.swift`, `App/LatchkeyApp.swift`, `Latchkey/Info.plist`, Settings, `testing/harness/fake_gateway.py`, the session suite; stage 2 adds a `ShareExtension/` target, an entitlements file and a pbxproj edit |

## 1. Why

The phone is where links and documents arrive and the crew is where they
should land. Today getting an article into a session means opening Latchkey,
finding the session, and pasting by hand; a PDF cannot be got in at all from
the phone. The flow should be: share sheet → Latchkey → the session it went
to last time, preselected → Send → watch it arrive.

Two facts, both read from the code rather than assumed, shape everything
below:

- **The gateway takes a message and a file over plain HTTP** with the
  dashboard's cookie, and nothing else (§4.5). There is no client "send" frame
  on its WebSocket.
- **Only the app process has the tailnet.** The node, its SOCKS5 proxy and the
  signed-in dashboard all live in the app process (§4.4). Any other process
  — a share extension in particular — can capture, but cannot deliver.

So the design is one app-side flow with more than one way in. The entry
points differ in cost; the delivery does not.

## 2. What the owner sees

### Working

1. In Safari (or Files, Mail, …) he shares an article or a PDF. Depending on
   the stage built (§4.2): a "Send to Latchkey" action in the share sheet
   (stage 1, a Shortcut he made once), or the Latchkey icon in the app row
   (stage 2).
2. **Stage 1:** Latchkey comes to the front at once. **Stage 2:** a small
   sheet shows what is being shared (title and link, or file name and size),
   a note field, and *Save for Latchkey*. It then says "Saved. Open Latchkey
   to send it." and closes. Nothing has been sent yet, and the sheet says so.
3. In Latchkey, the **destination picker** is up: the current gateway named
   at the top, its sessions listed newest-activity first with their folder,
   and **the session he sent to last time already selected**. One tap changes
   it. A note field (prefilled if he typed one in the extension). *Send*.
4. A short progress line — "Listing sessions", "Uploading 3 of 13",
   "Sending" — then one of:
   - **Sent** — and the dashboard moves to that session, so he watches it
     arrive as if he had typed it there;
   - **Queued** — "The session is mid-turn; the gateway queued it." Not an
     error, and said as such.
5. If several things were shared before he opened the app, they go one at a
   time, "1 of 3", each with its own destination (defaulting to the last used).

Settings → **Share** shows what is waiting (source, kind, size, when), the
last outcome, and *Retry* / *Delete* per item. Settings → Diagnostics → Logs
carries one line per step (§4.4, "how he knows").

### Failing

Every failure keeps the item and says what happened. A silent failure is a
bug in this spec.

| Failure | What he sees | Then |
|---|---|---|
| Gateway unreachable (tailnet down, gateway off, phone offline) | "Couldn't reach `<gateway>`. Kept — it will be sent when the gateway is back." with *Retry* | Retried automatically on the next foreground while the item is pending, up to 5 automatic attempts, then only by *Retry* |
| No gateway chosen yet (first run) | The gateway picker, then the share picker | — |
| Not signed in / token expired (`403` + `X-Auth-Required` on the list or the post) | The existing sign-in sheet, with a line above the page: "1 share waiting for sign-in" | After sign-in the delivery resumes by itself; nothing is re-shared |
| The remembered session is gone (not in the list just fetched) | The picker with nothing selected and "The session you used last time isn't there any more — pick one." | Never posts the stale key (§4.5, the silent-create trap) |
| The gateway refuses the post (`403` without the auth header — the 8443 origin case, F1 §4a) | "`<gateway>` refused the message (403). Open the session with it prefilled instead?" | Prefill fallback (§4.9): the composer holds the text for 30 s, he taps the page's own Send |
| A busy session | "Queued" (see above) | — |
| File over 50 MB | Refused **at capture**: "Files over 50 MB can't be sent — that's the gateway's limit." Nothing is staged | — |
| The gateway refuses the file (`413`, or `400` unsupported type / content mismatch) | The gateway's own `error` text, verbatim, e.g. "Unsupported file type: .bin" | *Delete* or keep |
| Upload interrupted mid-way | "Upload failed after `<n>` of `<m>` chunks." with *Retry* | Retry uploads again from the start (uploads are not resumable) |
| Post accepted but the page cannot show the session (navigation fails) | "Sent" stands (server-confirmed); the page is reloaded on `/chat?sid=<key>` | — |
| Inbox full (20 items or 200 MB) when sharing | Extension / intent: "Latchkey has `<n>` shares waiting. Open it to send them before sharing more." | — |
| The app is never opened again | Nothing is sent. Items older than 7 days are removed by whichever process next looks at the inbox (§4.3). Deleting the app deletes the inbox with it | — |
| Two sheets would overlap (Settings or the sign-in sheet is up) | The share picker waits until the other sheet is gone (the M4/M5 rule) | — |

## 3. Non-goals

- **No new sessions from the share flow.** Sharing adds to a session that
  exists. `POST /api/chat/slots` is there when wanted (§6 answer 3).
- **No archived sessions.** Only live slots (`GET /api/chat/slots`); the
  archive (`GET /api/sessions`) needs a resume first and is a different flow.
- **The app never fetches the shared URL.** Title and URL come from the
  sharing app; nothing about the link is looked up. R3's single-origin rule
  stands: the web view shows the gateway and nothing else.
- **No video.** The gateway streams video to 512 MB; this flow caps
  everything at 50 MB and does not special-case video containers.
- **The extension never picks a destination.** It captures; the picker is in
  the app, where the live list is (§4.7).
- **No background delivery** (BGTask). Why, in §4.4.
- **No notification** unless Olof says so (§8 Q2; R34/D6).
- **No delivery from any process but the app** (§4.4).

## 4. Design

### 4.1 The shape: capture → inbox → deliver

```
[share sheet / Shortcut / URL]        [Latchkey, foreground, page signed in]
   capture the payload  ─────►  inbox on disk  ─────►  ShareDelivery
   (extension, intent,           (§4.3)                 list → verify → upload → post → navigate
    or URL handler)                                     (§4.5, page world of the WKWebView)
```

Every entry point ends by writing one `ShareItem` into the inbox. Every
delivery starts by reading one. The app drains the inbox when it becomes
active and whenever an item is added while it is active. Nothing is ever
sent from the capture side.

### 4.2 Entry points, by stage

**Stage 1 — no new target.**

- **URL scheme** `latchkey://share?url=<https URL>&title=<text>&text=<text>`,
  declared as `CFBundleURLTypes` in `Latchkey/Info.plist` (the file exists and
  is empty; `GENERATE_INFOPLIST_FILE = YES` merges it — an array of
  dictionaries does not fit the `INFOPLIST_KEY_` form, so this corrects the
  earlier note). Handled in `LatchkeyApp.swift` with `.onOpenURL` →
  `ShareURL.parse` (pure) → `ShareInbox.add`. Links and text only.
  Hardening, since any app or web page can open it: only `http`/`https`
  URLs; `url` ≤ 8 KB, `title` ≤ 1 KB, `text` ≤ 64 KB; **any parameter naming
  a gateway or session is ignored** — the destination is chosen in the app,
  and there is no auto-send from a URL, ever.
- **App Intent** `SendToSessionIntent` (`App/Share/ShareIntents.swift`):
  `static let supportedModes: IntentModes = .foreground(.immediate)`, so it
  runs *in the app process* with the app in front. Parameters: `url: URL?`,
  `title: String?`, `text: String?`, `file: IntentFile?`, `note: String?`.
  `perform()` writes the item and returns `.result()`; the picker then
  appears through the same path as any other item. **This is what carries
  documents in stage 1:** an `IntentFile` from Shortcuts arrives in the app's
  own process — `fileURL` when Shortcuts staged it on disk (copied with
  `FileManager.copyItem`, no bytes through memory), else `data` (≤ 50 MB,
  fine in the app's budget, written straight to the inbox). No App Group, no
  extension memory limit, and a *supported* foreground hand-off.
- **Owner-made Shortcut** "Send to Latchkey": *Show in Share Sheet*, input
  types URLs, Safari web pages, text, files, PDFs, images; one action, this
  intent, with the Shortcut input in `url`/`file`/`text` and — for Safari —
  *Get Details of Safari Web Page → Name* in `title`. It appears in the
  share sheet's actions list, not the app row. Owner action (§8).

**Stage 2 — the share sheet's app row.**

- `ShareExtension/` target (`net.lixom.latchkey.share`,
  `NSExtensionPointIdentifier = com.apple.share-services`), sources *outside*
  `App/` (that folder is a synchronized group compiled into the app target).
  Activation rule: `NSExtensionActivationSupportsWebURLWithMaxCount = 1`,
  `NSExtensionActivationSupportsText = YES`,
  `NSExtensionActivationSupportsFileWithMaxCount = 1`. It links **no**
  TailscaleKit and no `TSNet/` code.
- `ShareViewController: UIViewController` hosting a SwiftUI
  `ShareCaptureView` (what is shared, a note, *Save for Latchkey*, the count
  of items already waiting). `SLComposeServiceViewController` is not used:
  it drags in the Social framework for a look this app does not need.
- On *Save*: `ShareInboxPolicy.admit` (size, count, byte total, extension
  advisory) → write the item (§4.3) → show "Saved. Open Latchkey to send
  it." for a second → `extensionContext.completeRequest`. On refusal, the
  reason, and *Cancel*.
- **No unsupported open.** The earlier draft tried the responder-chain
  `openURL:` "as a courtesy". Dropped: `NSExtensionContext.open` is documented
  for Today and iMessage extensions only, the trick is unsupported, and a
  hand-off that works some of the time teaches the owner to expect it and
  then to lose shares when it does not. The extension's own text is the
  bounce until §8 Q2 is answered.
- Shared source: `App/Share/Inbox/{ShareItem,ShareInboxPolicy,ShareInboxStore}.swift`
  are compiled into both targets (per-file membership exception on the
  synchronized group — one pbxproj edit, the same mechanism `TSNet/` uses).

Both stages write the same item and land in the same picker.

### 4.3 The inbox

**Where.** `ShareInboxStore.locations`, drained in this order:

1. the App Group container `group.net.lixom.latchkey` →
   `Library/Application Support/ShareInbox/`, when
   `FileManager.default.containerURL(forSecurityApplicationGroupIdentifier:)`
   returns one (stage 2 built, entitlement present);
2. the app's own `WorkspaceStore.appSupportDir/ShareInbox/` (stage 1; the
   fallback if the entitlement is absent).

Stage 1 uses only the second. Stage 2 adds the first without a migration:
the app reads both, and the intent and URL handler keep writing to whichever
`ShareInboxStore.writeLocation` resolves to (the group container when it
exists, so one process never has to look in two places for its own writes).

**Identifier.** `group.net.lixom.latchkey` (matches the app's
`PRODUCT_BUNDLE_IDENTIFIER = net.lixom.latchkey`,
`Latchkey.xcodeproj/project.pbxproj:295`).

**Unverified, and stage 2 rests on it:** whether an App Group can be
registered at all under Olof's **free Personal Team**. Apple's free
provisioning excludes several capabilities, and App Groups is commonly listed
among them — if that holds here, **stage 2 is blocked until a paid membership
exists**, and no amount of design works around it. Do not treat the earlier
"available on the free personal team" claim as established; it was asserted
without a signing attempt to back it.

This is cheap to settle and costs nothing until stage 2 is wanted: add the
entitlement to the app target in Xcode and press Run once. Xcode registers an
App Group when it signs automatically; `xcodebuild` here cannot (no usable
Apple ID for that step, DECISIONS 2026-09-23). Either it signs — the group
exists and stage 2 is open — or it refuses with a capability error, which is
the answer.

Stage 1 is unaffected either way: it writes to the **app's own container**, so
it needs no group and no entitlement. That asymmetry is another argument for
the staging recommendation in §8 Q1.

**Layout.** One directory per item:

```
ShareInbox/
  <uuid>/item.json      written LAST; an item without it does not exist
  <uuid>/payload        the document's bytes, only for kind = document
  .staging/<uuid>/      where a writer assembles an item before renaming it in
```

`item.json` (`ShareItem`, `Codable`, `version: 1`):
`id`, `kind` (`link` | `text` | `document`), `url?`, `title?`, `text?`,
`note?`, `filename?` (sanitised to `[\w.\-]`, as the gateway does),
`utType?`, `byteCount`, `createdAt`, `source` (`urlScheme` | `intent` |
`extension`), `state` (`pending` | `sending` | `failed`), `attempts` (count),
`lastError?`, `lastAttemptAt?`.

**Who writes.** The extension (stage 2), the intent and the URL handler (in
the app). A writer assembles under `.staging/<uuid>/`, writes `payload`
first, `item.json` last, then `FileManager.moveItem` renames the directory
into place — one atomic rename on the same volume, so a reader never sees a
half-written item. `.staging` entries older than 10 minutes are a crashed
writer's and are removed by the next sweep.

**Who reads.** The app only (`ShareInboxStore.pending()`), on `scenePhase ==
.active` and after each `add`.

**Who deletes.**
- The app: an item the gateway confirmed (`sent`, `queued`) is deleted at
  once, payload and all; a `failed` item on *Delete* in Settings → Share, or
  by the sweep.
- **The sweep** (`ShareInboxPolicy.sweep`, pure, shared source): items whose
  `createdAt` is older than **7 days**, and stale `.staging` directories. Run
  by the app at every launch, and by the extension before every write — so
  an inbox nobody opens the app for cannot fill forever. The extension
  deletes nothing else: never a fresh pending item, never one in `sending`.
- Deleting the app deletes both containers.

**Size and lifetime policy** (`ShareInboxPolicy`, pure):
- one document ≤ **50 MB** (the gateway's `_MAX_UPLOAD_BYTES`,
  `handlers/files.py:959`) — refused at capture, before any copy;
- at most **20 items** and **200 MB** in the inbox — refused at capture with
  the count shown;
- lifetime **7 days**;
- extension allowlist mirrored from `files.py` (`_ALLOWED_IMAGE_EXT |
  _ALLOWED_TEXT_EXT | _ALLOWED_DOC_EXT`) as an **advisory** at capture
  ("the gateway may refuse `.bin`") — the gateway's own answer is
  authoritative, so a drift between versions costs a clearer message, never
  a wrongly refused share.

**What happens with a 50 MB file in the extension.** The extension process
has an observed hard limit of about 120 MB. It never loads the bytes:
`NSItemProvider.loadFileRepresentation(for:openInPlace:completionHandler:)`
hands it a temporary file URL, valid inside the handler, and the handler
does `FileManager.copyItem` into `.staging/` — a kernel copy (an APFS clone
when on the same volume), no `Data` in the process. `loadDataRepresentation`
and `loadItem` are not used for files, and a code comment says why. Item
providers that offer only in-memory data (rare for files) are refused above
8 MB with "Share this from Files instead." The 50 MB check reads the file's
size from the URL before copying.

**Backup.** `BackupExclusion.exclude` is applied to the inbox directory by
whichever process creates it: shared content is transient, and a restored
phone should start clean (R5's reasoning).

**Never launched.** Covered above: nothing is sent, the count is shown at
the next share, 7-day items go at the next sweep, the cap refuses new ones,
and the app's deletion removes the rest.

### 4.4 The network path — read from the code, not assumed

What `app/TSNet/TSNetManager.swift` and `app/App/Workspace/` actually do:

- `WorkspaceManager` creates one `Workspace` per definition; each constructs
  `TSNetManager(config:)`, which constructs **one `TailscaleNode` in the app
  process**, its state directory `WorkspaceStore.stateDir(id)` under the app
  container's Application Support — not the group container. The node's
  private key lives there (R5 excludes it from backup).
- The node's SOCKS5 proxy and LocalAPI are one loopback listener with a
  **per-launch credential** (`LoopbackConfig.proxyCredential`), fronted by the
  app-owned `SocksLogProxy` relay on another loopback port. WebKit is handed a
  `ProxyConfiguration` from `ProxyConfigurationFactory` (`allowFailover =
  false`, `matchDomains` from `StableProxyPolicy`).
- `willEnterBackground` leaves "tsnet, proxy, and observers unchanged"; iOS
  then suspends the process, and recovery is *reactive* on the next
  foreground (`willEnterForeground`: "no lifecycle recovery; awaiting actual
  socket errors"; the relay listener is probed). M6 recorded that real
  suspension, jetsam and listener reclamation are device-only behaviours.
- A cold node start to `Running` is seconds on a good day and was ~66 s in
  the M6.8 flake. `startTailscaleIfNeeded` is guarded by `startInFlight`.
- The dashboard session is the page's: `SessionManager` asks the gateway
  *as the page* (`PageScriptSources.sessionFetch` via `callAsyncJavaScript`
  in the `latchkey-session` content world), so cookies, `Origin` and the
  page's refresh cycle are the page's. R32 chose this over URLSession
  precisely to extract no credential.

The options, weighed against that:

| Option | Verdict | Why |
|---|---|---|
| **The extension brings up its own node** | **No** | A node is a key and a state directory. The app's directory is in the app container, unreadable to the extension — and even if shared, two tsnet servers on one state directory is the failure `tailscaleUp`'s comment already warns about. A *fresh* node in the group container is a new identity: its own interactive login (in a share sheet), its own tailnet-lock signature (a manual step per new node, DECISIONS 2026-09-23), its own move out of purgatory (O3b), and — with `pin_scope: node` — its own dashboard sign-in at every gateway. Plus the Go runtime, WireGuard and netstack inside a ~120 MB process, and a share sheet that may sit for a minute waiting for `Running`. |
| **The extension dials the app's loopback proxy** (127.0.0.1 is host-wide) | **No** | The app is backgrounded the moment the share sheet is up in another app, and suspended seconds later; a suspended process accepts nothing, and iOS may reclaim its listeners. The extension would also need the port and the per-launch credential handed over through the group container, and would still have no dashboard cookie: that lives in the app's `WKWebsiteDataStore`. A race against suspension with a credential hand-off is not a design. |
| **The app delivers in the background** (`BGAppRefreshTask` / `BGProcessingTask`) | **No** | iOS schedules these when it likes — minutes to hours, not at all on a low battery — so "delivered" would still be unknown to the owner until he looks. Inside the ~30 s refresh budget the node must come up (cold: seconds to a minute) and the page must load and be signed in, or the app must go around the page with a copied cookie (the URLSession route below). The one thing it would buy — delivery while the owner does not have the app open — it cannot promise. |
| **The app's own `URLSession` through the proxy, with the session cookie copied out of WebKit** | **Kept in reserve, not chosen** (§4.9) | It works — discovery already builds an ephemeral session from `proxyConfiguration` — and it streams a file from disk. But it copies `mc_token_<port>` out of the page's store and forges `Origin`, the exact line R32 drew, and it makes a second auth path that must track the page's refresh cycle. Only if the page-world upload proves too heavy on the device, and only with Olof's say. |
| **The extension stages the payload; the app delivers in the foreground, in the page world** | **Chosen** | The only route on which everything that must be true is true by construction: the node is up (the app is in front), the page is loaded and signed in (`SessionManager.state == .active`), the cookies and `Origin` are the page's own, the split tunnel and ATS apply unchanged, and the owner is *looking* when the outcome is known. |

**The honest cost:** nothing is delivered until Latchkey is opened. Stage 1
opens it for him (a foreground intent); stage 2 tells him to ("Saved. Open
Latchkey to send it."). Neither pretends otherwise.

**How the owner knows whether a share was delivered:**

1. **In the flow:** the result line — *Sent* / *Queued* / the failure with
   its reason — is shown only after the gateway's JSON answered
   (`{"ok":true,…}`), never on the app's own say-so; and the page is moved to
   the session, so the message is visible in the transcript.
2. **Later:** Settings → Share lists what is still waiting and the last
   outcome per item; an empty list means everything shared has been
   confirmed by a gateway.
3. **Evidence:** Settings → Diagnostics → Logs, one line per step, none
   carrying content (D1): `Share: received <id> (<kind>, <bytes> B) via
   <source>`, `Share: listed <n> session(s) on <gateway host>`, `Share:
   uploaded <id> (<bytes> B) as <ext>`, `Share: sent <id> to <slot key>` /
   `… (queued)`, `Share: failed <id>: <reason>`, `Share: swept <n> item(s)`.
4. **From the sharing app's side, nothing** beyond "saved". That is the
   truth of the process boundary and the spec does not paper over it.

**Ordering.** `ShareDelivery` runs only when *all* hold: the app is active,
the workspace has a gateway, the current tab's `BrowserViewModel.sessionOrigin`
is that gateway, and `SessionManager.state == .active`. Otherwise it waits and
says what it is waiting for ("waiting for sign-in", "waiting for the
gateway"). After 20 s of the page not becoming active on a foreground it
shows the unreachable failure with *Retry*; a `needsToken` state shows the
sign-in sheet instead and waits indefinitely. It never starts on
`scenePhase == .active` alone — the L2 test in §6 exists to catch exactly
that regression.

### 4.5 Delivery, and the gateway API as verified

All references are into the installed 0.6.0 at
`~/.kiro/crew-venv/lib/python3.12/site-packages/kiro_crew/`, read, not run.

| Step | Call (page world, `credentials: 'same-origin'`, header `X-Latchkey-Share: <item id>`) | Verified |
|---|---|---|
| List | `GET /api/chat/slots` → JSON array; per slot `key`, `title`, `folder_id`, `agent`, `mode`, `surface`, `running`, `queue_depth`, `last_activity_ts`, `last_message`, `memory_mode`, `pinned`, `subagents_running` | `routes/chat.py:50` → `chat_handlers.py:1066` → `state.serialize_slots` → `slot_projection.py` |
| Folders | `GET /api/chat/folders` → array with `id`, `name` (+ counts) | `routes/sessions.py:38` → `chat_folders.py:298` |
| Upload | `POST /api/upload/file`, multipart, part name `file`, filename kept → `{"paths": ["<server path>"]}`; refusals `413 {"error":"File too large (max 50MB)"}`, `400 {"error":"Unsupported file type: .x","code":"unsupported_file_type"}`, `400 {"error":"File content does not match its type: .x"}`, `400` too many files | `routes/taskrunner.py:55` → `handlers/files.py:1222`; limits `:959-966`; allowlists `:984-1040` |
| Send | `POST /api/chat?ws=1` `{"message": <text>, "slot": <key>}` → `{"ok":true,"slot":<key>,"mid"?:…}` at once; a busy slot → `{"ok":true,"queued":true,"queue_id"?:…}`; `409` for a member-reserved key or a memory-mode mismatch | `chat_handlers.py:212` (`api_chat`), receipt `:1009-1017`, queued `:583,641,716` |
| **The trap** | an unknown `slot` is **silently created** — `state.get_or_create_slot(slot_name, …)` at `chat_handlers.py:314` | a typo or a stale key makes a new session, not an error |
| Auth | the dashboard cookie `mc_token_<port>`; every non-GET is CSRF-checked against the origin allowlist (F1 §4a: port-blind in 0.6.0) | `server.py:653-707`, `urls.py:419-452` |
| Deep link | `/chat?sid=<key>` selects a session; `&prefill=<text>` is stored per slot with a timestamp and dropped after **30 s** (`Date.now()-ts>3e4`); `&autoSend=1` acts only when *no* session is active and then creates a **new** one — useless for an existing session | `App-*.js` (the effect that stores `{slotKey,prompt,ts}` and the reader that checks `3e4`) |

**What the dashboard's own composer sends after an upload** — the seam the
earlier draft left open, now read:

- the composer's send is `sendChat(message, slot, colorTheme, signal, meta,
  steer)` posting `{message, slot, …meta?}` to `/api/chat?ws=1`
  (`client-*.js`); `uploadFiles` posts a `FormData` of `file` parts and keeps
  the returned `paths`;
- an uploaded path reaches the agent as a **`[attached_file N] <path>` token
  in the message text** (`files.py:1322`, `chat_title.py:425`; the renderer's
  grammar is `/\[attached_file (\d+)\]([^\S\n]+)/` followed by the path,
  `fileTokens-*.js`);
- server-side, `acp/prompt_blocks.py:build_prompt_blocks` scans the message
  text for readable **image** paths and inlines them as image blocks; any
  other path (a PDF) stays in the text for a tool-capable agent to open —
  which is what "the artifact itself, as in the chat window" means in
  practice.

So the app posts the same thing: `message` = the token line(s) plus the
note; no `meta` (optional; `sendId` is a client-side reconciliation aid the
app does not need). **One detail to pin during build, not guess:** whether
the composer puts the token line before or after the typed text, and its
separator (one grep of the send path in `App-*.js` for the pending-files
join). The fake gateway asserts on the token grammar and the path, not the
order, so either answer passes; the choice is recorded in §9.

**`ShareDelivery.run(item)`** (`App/Share/ShareDelivery.swift`, `@MainActor`):

1. `list`: `GET /api/chat/slots` and `GET /api/chat/folders` (10 s). Filter
   to `surface == ""` and `mode != "member"` (what the sidebar shows); sort by
   `last_activity_ts` desc; attach folder names. 403 + `X-Auth-Required` →
   `.signedOut` (the sheet); other failure → `.unreachable`.
2. `pick`: the picker (§4.7) with the last destination preselected when its
   key is in *this* list; the owner taps Send with a key **from this list**.
3. `verify`: re-`GET /api/chat/slots` immediately before posting; if the key
   is absent → `.sessionGone`, back to the picker, nothing posted. The race
   left is one round trip wide; it is recorded here rather than hidden.
4. `upload` (documents): §4.6's chunked page-world upload → `paths[0]`;
   refusals → the gateway's `error` text.
5. `post`: `POST /api/chat?ws=1` with the message (§4.6) and the verified
   key (10 s) → `.sent(key)` / `.queued(key)` / `.refused(status, text)` /
   `.unreachable`.
6. `navigate`: in the page world, `history.pushState({}, '', '/chat?sid=<key>')`
   + `dispatchEvent(new PopStateEvent('popstate'))` (React Router follows
   popstate; no reload). If `location.search` does not carry the key within
   1 s, `BrowserViewModel.load(url:)` on the same-origin URL — allowed by
   `NavigationPolicy`.
7. `finish`: delete the item on `.sent`/`.queued`; otherwise `state =
   failed`, `lastError`, `attempts += 1`; `ShareDefaults.lastDestination[origin]
   = (key, title)` on success. Log one line.

`ShareOutcome` (`App/Share/ShareOutcome.swift`, pure, `nonisolated`, host-
tested like `DashboardSignOut`) maps `(status, body)` to the outcome and to
the sentence the owner reads.

### 4.6 What is sent

`ShareMessage` (pure):

- **link:** `title` line if present, then the URL, then a blank line and the
  note if typed. Olof: "the title and the URL, plus a note if typed."
- **text:** the text, blank line, note.
- **document:** `[attached_file 1] <server path>` line, then the note (order
  and separator pinned per §4.5). The gateway's `[attached_file N]` grammar
  needs the path exactly as returned; the app never edits it.

**The chunked page-world upload.** The file bytes must reach the page's
`fetch` without extracting a credential. `callAsyncJavaScript` takes strings,
not `Data`, so:

- `PageScriptSources.shareStageChunk` — arguments `id`, `chunk` (base64 of
  ≤ 4 MiB raw); in the app's content world: `atob` → `Uint8Array` →
  `parts.push(new Blob([bytes]))` on `window.__latchkeyShare[id]` (the app
  world's `window`, invisible to the page). 50 MB is 13 calls of ~5.6 MB
  strings, well inside IPC limits.
- `PageScriptSources.shareUpload` — `new Blob(parts)` → `FormData.append('file',
  blob, filename)` → `fetch('/api/upload/file', {method:'POST', body, credentials:
  'same-origin', headers:{'X-Latchkey-Share': id}, signal})` → returns
  `{status, body}`; clears the staged parts in `finally`.
- `PageScriptSources.shareFetch` — the JSON-returning sibling of
  `sessionFetch` (which returns only a status): `{status, body}` for the
  list, the folders and the post.

Memory, honestly: the staged blob holds the whole file in WebKit's processes
until the upload completes; the dashboard's own composer stages the same
50 MB, file-backed, which is cheaper. Progress is per chunk ("Uploading 3 of
13"). If the device shows the content process dying on a 50 MB share
(`AppDiagnostics.webContentTerminations` rises during a share), the ladder
is: 4 MiB → 1 MiB chunks first; then a `WKURLSchemeHandler` serving the
payload to a page-world `fetch` (CORS on a custom scheme — to be measured,
not assumed); and only then §4.9's URLSession route, with Olof's say.

### 4.7 The destination picker and the remembered default

`ShareDestinationView` (`App/Share/`), a sheet over `DashboardContent`,
obeying the one-sheet rule (it waits for Settings or the sign-in sheet):

- header: the item (title/URL, or filename and size), the gateway host, and
  "Change gateway…" which runs the existing `GatewayPickerView` →
  `workspace.selectGateway` and then waits for the new page to sign in;
- the list from §4.5 step 1: title (or key when untitled), folder, a
  running/queued badge; accessibility ids `share-picker`, `share-session-<key>`,
  `share-destination-selected` (label = key), `share-note`, `share-send`,
  `share-result` (label = `sent:<key>` | `queued:<key>` | `failed:<reason>`),
  `share-cancel`;
- preselection: `ShareDefaults.lastDestination[origin]` when its key is in
  the list; if the last share went to a *different* gateway, a line "Last
  time: `<session>` on `<other gateway>` — switch?" that runs the gateway
  switch;
- one item at a time, "1 of `<n>`", oldest first.

`ShareDefaults` (`App/Share/ShareDefaults.swift`): `lastDestination: [origin:
(slotKey, slotTitle, at)]`, JSON at `appSupportDir/share-defaults.json`. Not
in `WorkspaceDefinition`: it is a share preference, not a workspace
property, and keeping it apart means a `-UITestResetWorkspaces` launch does
not have to know about it (the test hook `-UITestResetShare` clears it and
the inbox).

### 4.8 Files, types and functions

| File | What |
|---|---|
| `App/Share/Inbox/ShareItem.swift` | the `Codable` item, `version`, kinds, states — shared source |
| `App/Share/Inbox/ShareInboxPolicy.swift` | pure: `admit(byteCount:, extension:, inboxCount:, inboxBytes:) -> Admission`, `sweep(items:, now:) -> [id]`, the constants (50 MB, 20, 200 MB, 7 d, 10 min) — shared source, host-tested |
| `App/Share/Inbox/ShareInboxStore.swift` | `locations`, `writeLocation`, `add(_:payloadURL:)` (stage → rename), `pending()`, `delete(id)`, `markFailed`, `sweep()`; file IO in `nonisolated` helpers off the main actor — shared source |
| `App/Share/ShareURL.swift` | pure: `parse(URL) -> ShareItem?` with the caps and refusals — host-tested |
| `App/Share/ShareMessage.swift` | pure: the three message shapes — host-tested |
| `App/Share/ShareOutcome.swift` | pure: `(status, body) -> Outcome`, `sentence(for:)` — host-tested |
| `App/Share/ShareDelivery.swift` | `@MainActor` the sequence of §4.5, driven by `SessionManager.state` and the tab's origin; `retry(id)` |
| `App/Share/ShareDefaults.swift` | the last destination per origin |
| `App/Share/ShareDestinationView.swift` | the picker sheet (§4.7) |
| `App/Share/ShareIntents.swift` | `SendToSessionIntent` |
| `App/Share/ShareSettingsSection.swift` | Settings → Share: the waiting list, outcomes, Retry/Delete; ids `share-settings`, `share-waiting-count` |
| `App/Browser/PageScriptSources.swift` | `shareFetch`, `shareStageChunk`, `shareUpload`, `shareNavigate` (source text; `scripts/test-page-scripts.sh` runs them under Node against a fake `fetch`) |
| `App/Browser/BrowserViewModel.swift` | `SessionHost` gains `shareCall(script:arguments:timeout:) async -> [String: Any]?` beside `sessionFetchStatus` |
| `App/LatchkeyApp.swift` | `.onOpenURL { ShareURL.parse($0).map(inbox.add) }` |
| `Latchkey/Info.plist` | `CFBundleURLTypes` with scheme `latchkey` |
| `App/Diagnostics/AppDiagnostics.swift` | counters `sharesReceived`, `sharesSent`, `sharesQueued`, `sharesFailed`, `sharesSwept` |
| `App/TestHooks` (test builds) | `-UITestResetShare`; `-UITestSeedShare <kind>:<bytes>[:age=<days>d]` writes a synthetic item (a `%PDF-` header for `pdf`, random bytes for `bin`) into the inbox at launch; overlay ids `share-inbox-count`, `share-terminations` |
| `ShareExtension/` (stage 2) | `ShareViewController.swift`, `ShareCaptureView.swift`, `Info.plist` (activation rule), `ShareExtension.entitlements` |
| `Latchkey.entitlements` (stage 2) | `com.apple.security.application-groups = [group.net.lixom.latchkey]`; `CODE_SIGN_ENTITLEMENTS` in the pbxproj for both targets |
| `testing/harness/fake_gateway.py` | the four routes with the real shapes, counters and controls (§6) |

**Invariants this must not break** (`../../app/AGENTS.md`):
- the split tunnel decides what goes through the proxy; only tailnet hosts
  do — the share's requests are the page's, on the page's proxied session;
  nothing new is routed;
- `allowFailover` stays false — the factory is untouched;
- ATS stays on with no exceptions; the share never loads anything but the
  gateway's own origin, and never fetches the shared URL;
- D1: no app or node logs leave the device, and no log line carries a URL,
  title, note, filename or content (item ids, kinds, byte counts and
  extensions only; `LogRedaction.scrub` remains the backstop);
- R3: the main frame stays on the gateway; `/chat?sid=` is same-origin;
- R32's line: no credential is copied out of WebKit (§4.4, §4.9);
- a vendored-tree change is its own commit (R16) — none is needed here;
- the extension never links TailscaleKit or touches the node's state
  directory.

### 4.9 Kept in reserve

- **Prefill** (`/chat?sid=<key>&prefill=<text>`): no API call, "review
  before send", 30 s. Wired as the offer when a post is refused (the 8443
  origin case before F1 §4a is fixed). Links and text only.
- **URLSession through the proxy with the copied cookie**: the last rung of
  §4.6's ladder, and a design line not crossed without Olof.
- **A cached session list in the extension**, so stage 2 could preselect
  before the app opens: not until it is known whether a cached list is ever
  right; the app re-lists before posting regardless.

## 5. State and migration

| What | Where | Previous version | Downgrade |
|---|---|---|---|
| Inbox items and payloads | `ShareInbox/` in the app container (stage 1) and/or the group container (stage 2); `isExcludedFromBackup` | did not exist; nothing to migrate | an older build ignores the directory; the sweep of a newer build removes 7-day items |
| `item.json` | `version: 1`; unknown fields ignored, a higher `version` is left alone and logged | — | — |
| Last destination | `appSupportDir/share-defaults.json` | did not exist | ignored by an older build |
| The URL scheme | `Info.plist` | none | an older build has no handler: iOS shows nothing for `latchkey://`; the Shortcut's intent is absent too |
| The App Group (stage 2) | entitlement on both targets | none | removing it later orphans the group container's inbox until the app is deleted — the app keeps reading both locations, so the items are still drained first |

Nothing here touches `WorkspaceDefinition`, `HomePage.url`, the node's state
directory or WebKit's store.

## 6. Decisions — answered by Olof, 2026-09-23

1. **Default destination: remember the last session, preselected.** The
   picker still opens, so one tap changes it.
2. **What arrives: the title and the URL, plus a note if typed** — and, for
   a document, **the artifact itself with a note**, "similar to how it would
   be in the chat window of kirocrew or a web session". Folded in: §4.3,
   §4.5, §4.6.
3. **New sessions:** not answered, and not needed for a first cut.

## 7. End-to-end tests

Suites: host `make test-policy` (new `scripts/test-share.sh`, `swiftc`
against the pure files, like `test-signout.sh`); **session**
`scripts/test-session.sh` against the real 0.6.0 bundle (new
`UITests/ShareTests.swift`; the script's expected count sums both classes);
**L2** `scripts/test-tailnet.sh` (one test, on the real node); L1 gains
nothing — the flow adds no routing. Server-side evidence throughout (R13).

**The fake gateway grows** (`testing/harness/fake_gateway.py`), with the real
shapes read from 0.6.0: `GET /api/chat/slots` (a configurable list; default
three slots in two folders, one `running`), `GET /api/chat/folders`, `POST
/api/upload/file` (multipart, part name `file`, the 50 MB and extension
rules, `{"paths": […]}`), `POST /api/chat` (requires `slot`; `{"ok":true,
"slot":…}`; `{"ok":true,"queued":true}` for the busy slot; **any `slot` not in
the current list is recorded as a `violation` and answered 404** — the fake
refuses what the real gateway would silently create, so the trap is a test
failure rather than a stray session). Counters `slot_lists`, `share_posts`,
`share_uploads`, `upload_bytes`, `share_denials`; a `posts` journal of
`{slot, message, item}` keyed by the `X-Latchkey-Share` header. Controls:
`/__slots?keys=a,b,c&busy=b`, `/__upload-limit?bytes=`, `/__csrf-deny?on=1`.
`gateway_check.py` gains steps for each.

**Seeding without the extension.** XCUITest cannot attach to an extension
process, and the intent is not drivable from XCUITest. Links enter through
the URL scheme (`XCUIDevice.shared.system.open`); documents through the
test-hook `-UITestSeedShare` (test builds only, R15), which writes exactly
what the extension would write. That tests the inbox-to-gateway path fully
and the capture side not at all — the capture side is the device's (below).

| Test | Suite | Asserts | Shown to fail by |
|---|---|---|---|
| `ShareMessage` formats the three shapes | host | link = title, URL, blank, note; text; document = `[attached_file 1] <path>` + note; no trailing whitespace; note omitted when empty | changing the blank-line separator |
| `ShareOutcome` maps every answer | host | `{ok,slot}`→sent; `{ok,queued}`→queued; 403+`X-Auth-Required`→signedOut; bare 403→refused(403); 413→tooLarge(gateway text); 400 `{error}`→refused(text); no answer→unreachable; and the sentence for each | treating `queued` as `sent` (the earlier draft's named hazard) |
| `ShareInboxPolicy` admits and sweeps | host | refuses > 50 MB, a 21st item, a 201st MB; advisory for `.bin`; sweeps 7-day items and 10-minute staging dirs; keeps a 6-day item | an 8-day-old item kept |
| `ShareURL.parse` is hardened | host | accepts `https`; refuses `javascript:`, `data:`, `file:`, `ftp:`; caps sizes; **ignores `gateway=`/`slot=` parameters** | accepting `javascript:` |
| `ShareItem` round-trips | host | encode → decode equal; unknown field ignored; `version: 2` left alone | dropping `source` |
| The page scripts run | host (`test-page-scripts.sh`, Node) | `shareStageChunk` + `shareUpload` post one `FormData` whose `file` part has the staged byte count; `shareFetch` returns `{status, body}` | dropping the last chunk |
| A shared link reaches the chosen session | session | `system.open("latchkey://share?url=https://example.com/a-XYZ&title=A")` → the app is frontmost with `share-picker` → tap `share-session-obsidian` → `share-send` → `/__state.posts` holds one post with `slot == "obsidian"` and a message containing the title and the URL; `share-result` = `sent:obsidian`; the page's URL carries `sid=obsidian` (the fake's request journal shows the navigation or the SPA's refetch for that slot) | posting without `slot`: the fake 400s and `share_posts` stays 0 |
| The last session is preselected | session | share twice; on the second, `share-destination-selected` = the first's key before any tap, and Send posts to it | not writing `share-defaults.json` |
| Only a listed slot is ever posted | session | after a share to `obsidian`, `/__slots?keys=notes,plan` → next share → the picker shows nothing selected and the "isn't there any more" line; `share_posts` unchanged; **`violations` empty** | posting the remembered key: the fake records a violation |
| A busy slot is "queued", not "sent" | session | `/__slots?…&busy=obsidian` → `share-result` = `queued:obsidian`, and the item is gone from the inbox (`share-inbox-count` = 0) | mapping `queued` to `sent:` |
| A refused post offers prefill | session | `/__csrf-deny?on=1` → `share-result` = `failed:refused-403` and a `share-prefill` button; tapping it → the fake's journal shows `GET /chat?sid=obsidian&prefill=…`; the item stays (`share-inbox-count` = 1) | swallowing the 403 (`share-result` says sent) |
| Signed out mid-share, then resumed | session | `/__expire` + `/__revoke` before Send → `token-sheet` appears, `share-waiting-count` = 1; `signIn(kind: "cli")` → without any further tap, `share_posts` becomes 1 and `share-result` = `sent:…` | dropping the item on 403 |
| A cold launch keeps the item | session | open the share URL, `app.terminate()` before Send, `launch(reset: false)` → `share-picker` reappears with the same title | a memory-only inbox |
| A document is uploaded, then referenced | session | `-UITestSeedShare pdf:1048576` → Send → `share_uploads` = 1, `upload_bytes` = 1048576, the part's filename ends `.pdf`; then one post whose message matches `\[attached_file 1\][ \t]+<the path the fake returned>`; `share-inbox-count` = 0 afterwards | posting before uploading: the message names no returned path → the fake records a violation |
| 50 MB goes through, byte for byte | session | `-UITestSeedShare pdf:52428800` → `upload_bytes` = 52428800 and `share-terminations` unchanged across the share; elapsed logged | a 64 MiB chunk (one call) — or, cheaper, dropping the last chunk: the byte count differs |
| Over the limit is refused at capture; a gateway 413 is shown | session | `pdf:52428801` → `share-inbox-count` = 0 and the log line `Share: refused … over 50 MB`; then `/__upload-limit?bytes=1048576` + `pdf:2097152` → `share-result` = `failed:File too large (max 1MB)` (the fake's text) | ignoring the 413 |
| An unsupported type shows the gateway's words | session | `bin:1024` → `share-result` = `failed:Unsupported file type: .bin` | swallowing the 400 |
| Unreachable, kept, retried | session | `/__restart?down=8` + proxy blackhole → `share-result` = `failed:unreachable`, `share-inbox-count` = 1; blackhole off, tap `share-retry` → `share_posts` = 1 | deleting the item on failure |
| The sweep runs at launch | session | `pdf:1024:age=8d` → `share-inbox-count` = 0 and `Share: swept 1 item(s)` in the unified log | no sweep |
| Nothing about the share is logged (D1) | session (the script) | share `https://example.com/secret-XYZ` with note `NOTE-XYZ` and a file `secret-XYZ.pdf`; the unified log and the app container's Logs contain no `XYZ`; validated by ≥ 1 `Share: sent` line in the same log | logging the URL |
| Delivery waits for the page, on the real node | L2 | with the fake gateway behind the `gw` peer (F1's harness wiring), the app launched **by the share URL from terminated**; the node comes up, the page loads and is signed in; then exactly one post arrives *through the peer* (the fake sees the node's forward, not loopback) and `share_denials` = 0 | starting on `scenePhase == .active`: a post before sign-in → a denial with the share header |
| The share sheet route (stage 2) | session, full tier; **fragile by nature** | drive Safari to the fake dashboard, Share → *Latchkey* → *Save* → the group container (`simctl get_app_container … groups`) holds one item with `source: extension`; then relaunch the app and the ordinary link test's assertions | building without the extension: no app row; or writing `item.json` first: the item is visible before its payload |

**What only the device can show** (added to `DEVICE-CHECK.md` §6 when
built): the Shortcut appears in Safari's and Files' share sheets and opens
the app with the item (stage 1); a 50 MB PDF from Files is captured by the
extension without it being killed (Settings → Share shows the byte count;
Settings → Privacy → Analytics shows no jetsam of the extension) (stage 2);
a share made with the phone offline is delivered the next time the app is
opened on the tailnet; a real gateway's `[attached_file 1]` renders the PDF
in the transcript.

## 7a. Acceptance criteria

- **A link share is server-confirmed within 10 s** of the app coming to the
  front with the page already signed in (simulator). Instrument: the fake's
  `posts` journal timestamp against the `Share: received` log line.
- **No post ever names an unlisted slot.** Instrument: `/__state.violations`
  empty after the whole session suite.
- **Every outcome is shown, and "sent" is never shown unstamped.**
  Instrument: `share-result` in each test equals the fake's counters
  (`share_posts` incremented iff `sent:`/`queued:`).
- **A document arrives whole.** Instrument: `upload_bytes` equals the seeded
  size at 1 MiB and 50 MiB; `share-terminations` unchanged.
- **The inbox is bounded and self-cleaning.** Instrument: `share-inbox-count`
  after the sweep test; the script's listing of the container's `ShareInbox/`
  shows no item older than 7 days and no `.staging` entry.
- **D1 holds.** Instrument: the script's grep for the marker strings, validated
  by a `Share: sent` line.
- **Host coverage.** `make test-policy` gains `scripts/test-share.sh` with at
  least 40 checks, all green.
- **Delivery order.** The L2 test passes with `share_denials` = 0.
- **On the device:** the four checks above, recorded in `DEVICE-CHECK.md`.

## 8. Open questions and owner actions

**Q1 — Stage 1 only, or both?** **Decided by Olof, 2026-09-24: stage 1
first, then stage 2 the same day** ("I want F3 stage 2 as well please").
The recommendation, kept for the record:

- Documents no longer pull the App Group forward: an `IntentFile` reaches
  the app's own process (§4.2), so stage 1 carries links *and* documents
  with no second target, no entitlement, no second profile, no
  memory-limited process and no unsupported hand-off.
- Stage 1's hand-off is *better* than stage 2's: a foreground intent brings
  Latchkey up with the picker; the extension can only say "open Latchkey".
- Stage 2 buys exactly two things — the app icon in the share sheet's app
  row, and no one-time Shortcut to make — at the cost of a target, an App
  Group entitlement (a new profile, hence an Xcode Run), a capture UI, a
  memory-limited copy, and a suite test that is fragile in the simulator.
- The inbox is designed group-container-ready (§4.3), so "both" later is
  additive: the extension target, the entitlement, and the one L2/session
  test in the table. Nothing in stage 1 is thrown away.

If Olof says "both", §4.2's stage 2 and §4.3's first location are built as
written, and Q2 needs an answer first.

**Q2 — Does R34/D6 ("no notifications in v1") cover a local notification
posted by the share extension?** **Decided by Olof, 2026-09-24: yes — no
notification.** "Saved. Open Latchkey to send it." is the bounce. A
notification is additive later: permission once, one post from the
extension after Save, nothing else changes.

**Q3 — New sessions from the share flow?** Still open; not needed.

**Owner actions:**
- **Stage 1:** make the "Send to Latchkey" Shortcut once (§4.2), with
  *Show in Share Sheet* on. Five minutes, on the phone.
- **Any gateway on 8443:** allow the ported origin first (F1 §4a), or every
  share there returns 403 and falls back to prefill.
- **Stage 2, once, in Xcode** (xcodebuild here cannot register an App
  Group or mint a profile):
  1. Open `app/Latchkey.xcodeproj`. For the **Latchkey** target, then the
     **ShareExtension** target: Signing & Capabilities, team `DX33PQ7J4A`,
     *Automatically manage signing* on. Each target shows **App Groups**
     with `group.net.lixom.latchkey` (from its `.entitlements`). If it is
     unticked or red, tick it or press the refresh button. Xcode then
     registers the group and the App ID `net.lixom.latchkey.share`.
  2. With the phone connected, **Run** once. This mints the development
     profiles for both bundle ids with the group. `make device` works after
     that, and not before: the old profile has no App Group.
  3. For TestFlight, **Product → Archive → Distribute App → App Store
     Connect** once from Xcode. This mints the App Store profiles for both
     ids, which `make tf` needs on disk because it exports without
     `-allowProvisioningUpdates`. Its preflight checks only the app's
     profile, so a missing extension profile shows up as an export error.
  4. On the phone: share a page from Safari. Latchkey is in the app row
     (possibly under *More* the first time). Save, open Latchkey, and send.
- **Device check** after the build: the four items in §7.

## 9. Log

- 2026-09-23: requested; two research strands (gateway API, iOS platform)
  reported the same day. First design: two stages, one app-side flow. Two
  findings shaped it: the extension can never send (one node, one state
  directory, `pin_scope: node`), and there is no supported way for a share
  extension to launch its containing app. A third went to F1 §4a: the
  gateway's origin allowlist is port-blind, so 8443 breaks every POST.
- 2026-09-23: Olof's answers (§6). Documents enlarge the feature.
- 2026-09-23, design pass to buildable:
  - **Network path decided and argued from the code** (§4.4): the app
    delivers, foreground, page world. The extension's own node, the app's
    loopback from another process, and BGTask delivery are each rejected
    with the lifecycle reason. The URLSession-with-cookie route is named,
    reserved, and gated on Olof.
  - **Documents through stage 1 after all:** `IntentFile` lands in the app
    process, so the App Group is a stage-2 cost only. README's "pulls the
    App Group inbox forward regardless" is corrected by this; the README
    row and its open item 1 need the parent's edit (not done here — one
    file only).
  - **The composer/send seam read** (§4.5): `sendChat` body, upload receipt,
    the `[attached_file N] <path>` grammar, and `build_prompt_blocks`. One
    ordering detail left to pin at build time, with the fake indifferent to
    it.
  - **Prefill semantics verified:** 30 s, per slot; `autoSend=1` only ever
    makes a new session.
  - **Dropped:** the responder-chain "courtesy" open (unsupported and
    non-deterministic), and the extension's local notification pending Q2
    (R34/D6). **Corrected:** `CFBundleURLTypes` goes in `Latchkey/Info.plist`,
    not an `INFOPLIST_KEY_`.
  - **The fake refuses the trap:** an unlisted `slot` is a recorded violation
    and a 404, so the silent-create hazard fails a test instead of minting a
    session.
- 2026-09-24, stage 1 built (Q1 decided by Olof: stage 1 only, first).
  URL scheme, `SendToSessionIntent`, the inbox, `ShareDelivery`, the
  picker, Settings → Share. The composer's attachment order, read from
  the 0.6.0 and 0.7.0 bundles (`fileTokens-*.js`, identical): typed text,
  then the `[attached_file N]` lines, joined by ONE newline — not the
  blank line §4.6 guessed. Step 6 is a same-origin load of
  `/chat?sid=<key>`: the SPA honours `sid` on a document load, but a
  `pushState` + `popstate` from outside only after an in-app navigation,
  and not on a phone layout. The sidebar filter is `surface` in
  {"", "orchestrator"} (0.6.0 also "crew"); there is no `mode` test.
  0.7.0 changes none of the four routes' shapes. Tests: host
  `test-share.sh` and the share page-script suite; 14 ShareTests in the
  session suite. They found two bugs: a seeded item never came up on a
  cold launch, and the fake answered a refused POST without reading its
  body, so the next request on the connection came back 501.
- 2026-09-24, stage 2 built (Olof: "I want F3 stage 2 as well please").
  **Q2 decided by Olof: no notification** (R34/D6); additive later. The
  `ShareExtension` target, the App Group `group.net.lixom.latchkey` on both
  targets, the capture sheet. Additive except for two small changes:
  `ShareInboxPolicy` no longer names `ShareOutcome` (the extension compiles
  the inbox files alone), and the single-root store gained a two-location
  view (`ShareInbox`) — §4.3 said the app reads both but stage 1 had no
  code for a second root. The spec's 8 MB in-memory rule is moot: the
  extension uses only `loadFileRepresentation`, so a file always arrives
  on disk. The share-sheet test drove Safari → Share → Latchkey → Save →
  the app on the iOS 27 simulator. It found a real bug: SwiftUI reports
  `.active` before `UIApplication.applicationState` does, so an item the
  extension saved was not brought up on return. The App Group was
  **not** tried on a device: that is the owner's Xcode step (§8).
- 2026-09-24: the session suite cannot run on this Mac. The venv moved to
  KiroCrew 0.7.0 and the desktop app to 0.7.1 the same evening; no
  pinned 0.6.0 remains, and none is on the package index. The fake must
  be re-pinned to 0.7.x before the session suite (all of ShareTests
  included) gives a verdict again.
