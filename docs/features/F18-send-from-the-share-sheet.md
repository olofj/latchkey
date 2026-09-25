# F18 — Finish the share inside the share sheet

| | |
|---|---|
| **Status** | options, not a design. Nothing is decided; §9 lists the questions whose answers pick one |
| **Requested** | 2026-09-25, for Olof: the share flow should finish inside the share sheet. He picks the target session from a drop-down there, with no switch into Latchkey. Today it is two steps: the extension writes to the App Group inbox, and the app posts it when opened (F3 stages 1-2) |
| **Revision** | needs one whichever option is chosen. F3 §3 says "the extension never picks a destination", and F3 §6 answer 1 says the picker always opens. Every option here changes at least one of those |
| **Touches** | `ShareExtension/`, `App/Share/` (a new session mirror, and `ShareDelivery` gains a pre-chosen destination), `App/Share/ShareIntents.swift` (options B and C), Settings → Share, the session suite |
| **Mocks** | [`../mocks/F18-share-sheet-options.html`](../mocks/F18-share-sheet-options.html): one column per option, open it in a browser |

## 1. Why

F3 stage 2 put Latchkey in the share sheet's app row, and it works as built.
But the owner does the share in two halves. He taps *Save for Latchkey*, gets
"Saved. Open Latchkey to send it.", then switches apps, and only then picks the
session and sends (`app/ShareExtension/ShareCaptureView.swift`, the `.saved`
case). He wants to choose the session where he started, and not switch at all.

## 2. The constraint, read from the code

Six facts decide what is possible. Each one comes from the tree at `63789dd`
or from the iOS 27.0 SDK on this Mac (`xcrun --sdk iphoneos
--show-sdk-version` → 27.0), not from memory.

**2.1 The extension cannot reach the gateway.** The gateway is a tailnet host.
The only route to it is the userspace node that `TSNetManager` builds in the
**app** process, one `TailscaleNode` per workspace. Its state directory is
`WorkspaceStore.stateDir(id)`, under the app container's Application Support
(`app/App/Workspace/WorkspaceStore.swift:435-480`). Latchkey installs no system
VPN, by design (`docs/PLAN.md:57`: "No system VPN. The app carries its own
userspace Tailscale node"). So the extension has no route to the gateway.
F3 §4.4 weighed the ways around this and rejected each for a lifecycle
reason:

- the extension could start its own node, but that means a new identity with
  its own login, its own tailnet-lock signature and its own dashboard sign-in
  under `pin_scope: node`;
- it could dial the app's loopback proxy, but the app is suspended while
  another app's share sheet is up, and the proxy's credential is per launch;
- a BGTask runs when iOS decides.

The extension is written to that: "It links no TailscaleKit and touches no
node state" (`ShareViewController.swift` header).

**2.2 Even with a route, it has no credential.** The dashboard cookie
`mc_token_<port>` lives in the workspace's `WKWebsiteDataStore(forIdentifier:
definition.dataStoreUUID)` (`App/Workspace/Workspace.swift:110`), which belongs
to the app. Every delivery call is made *as the page*, from the page world of
that web view (`ShareDelivery.call` → `PageScriptSources.shareFetch`; F3
§4.5-4.6). R32 drew the line at copying the cookie out of WebKit. F3 §4.9
keeps that route in reserve "with Olof's say".

**2.3 Nothing session-shaped is on disk where the extension can read it.**
The App Group `group.net.lixom.latchkey` is used by one type only,
`ShareInboxStore` (`App/Share/Inbox/ShareInboxStore.swift:35,178`;
`ShareCaptureModel.swift:65`). The extension can therefore read the inbox
items, their count and their bytes, and that is all. It cannot read any of the
things a drop-down would need:

| What the drop-down needs | Where it is today | Can the extension read it? |
|---|---|---|
| The session list | `ShareDelivery.sessions`, **in memory only**. `fetchSessions` runs `GET /api/chat/slots` at share time and writes the result nowhere (`ShareDelivery.swift:328-395`) | no, it is not on disk at all |
| The last destination per gateway | `appSupportDir/share-defaults.json` (`ShareDelivery.swift:130`, `ShareDefaults.swift`) | no, it is in the app container |
| The known gateways and the current one | `appSupportDir/workspaces.json` (`WorkspaceStore.swift:466-468`) | no, it is in the app container |
| Items waiting, and their count | the group container's `ShareInbox/` | **yes**. This is the "*n* shares are already waiting" line today |

So **a cached list does not exist yet**. Every option below that shows a
drop-down in the sheet needs the app to start writing one into the group
container (§6.1). This is new work, not a switch that already exists.

**2.4 The extension cannot bring the app to the front.**
`NSExtensionContext.open(_:completionHandler:)` is supported only by the
Today and iMessage extension points, and the share-services point is not one
of them. F3 §4.2 records this, and the extension's header says it:
"`NSExtensionContext.open` is not supported for share extensions, and the
responder-chain trick is not used". `completeRequest(returningItems:)` returns
items to the *host* app, such as Safari, and never to Latchkey. So from the
app-row extension **the switch is always manual**: the owner has to open
Latchkey himself. Nothing the extension does can start the send. I found no
SDK API that lets a share extension run an App Intent of its containing app.
That search was not exhaustive; §9 Q7 asks for it to be settled.

**2.5 The memory ceiling does not bind for these options.** F3 §4.3 and the
`ShareCaptureModel` header record "about 120 MB" as the extension's hard
limit. That figure is F3's observation. Apple does not publish it, and it has
not been measured in this repo. A session mirror is kilobytes. The ceiling
matters only for the rejected "own node in the extension" option: the Go
runtime, WireGuard and netstack inside ~120 MB, on top of the identity
problems in 2.1.

**2.6 The App Intent side can run in the app process without foregrounding
it.** The 27.0 SDK's `AppIntents.swiftinterface` declares `IntentModes` with
`.background`, `.foreground(.immediate | .deferred | .dynamic)`, and
`AppIntent.continueInForeground(_:alwaysConfirm:)` /
`needsToContinueInForegroundError`, all `anyAppleOS 26.0` (the deployment
target is 26.0, `project.pbxproj:576`). `SendToSessionIntent` declares
`.foreground(.immediate)` today (`ShareIntents.swift`), and the stage-1
Shortcut runs it. An intent in the app target runs in **the app's process**,
which is the one that has the node (2.1). This is the one supported way to
run code where the tailnet is without the owner switching apps. It works from
the Shortcut in the share sheet's *actions* list, **not** from the app-row
extension (2.4).

**What this means for the owner.** From the app-row icon, a drop-down is
possible (from a cache the app writes) and a confirmed send is not. A
confirmed send without a switch is possible only from the Shortcut action,
and only if a background intent can bring up the node and deliver within
whatever time iOS gives it. That budget is unmeasured (§4, C).

## 3. The tradeoff: verified, with one correction

The expected tradeoff was: a drop-down fed from a cached list is achievable
in the sheet, but delivery may still need the app, so the owner chooses
between "confirmed sent now, with a switch" and "queued silently, delivered
later". **Verified**, with two corrections.

1. **"Confirmed sent now, with a switch" is not on offer from the app-row
   icon.** The extension cannot make the switch (2.4). From that icon the
   choice is between *queued, delivered when you next open Latchkey* and
   *queued, with you opening Latchkey yourself now*. These are the same
   mechanism, and the second only happens because he chooses to do it. The
   switch that the app does for him exists only on the Shortcut route, where
   a foreground intent brings Latchkey up (option B).
2. **There is a third way that gets both, but not from the app row.** A
   background-mode intent runs in the app's process, where the node is (2.6),
   so the Shortcut action can show a session drop-down, deliver, and answer
   "Sent to obsidian" inside the share sheet (option C). It depends on two
   things nobody has measured: whether a cold node plus the page can finish
   inside the background budget, and whether the page world works at all
   while the app is backgrounded. If either fails, it either falls back to a
   switch (`continueInForeground`) or crosses R32's line.

## 4. Options

Every option keeps F3's rules:

- nothing is posted to a key that was not in a list fetched just before the
  post (the silent-create trap, F3 §4.5);
- "Sent" is shown only when the gateway's JSON says so;
- an item is never lost on failure.

Two options can be built side by side: A is for the app-row icon, and B or C
is for the Shortcut action.

### A — Drop-down in the app-row sheet, queued, delivered on next open

The sheet gains a **Session** drop-down, fed from a mirror the app writes
into the group container (§6.1), with the last destination preselected. The
button becomes *Queue for obsidian*. The item is written to the inbox with
`destination = {origin, slotKey, slotTitle}`. The next time the app is
active and signed in to that gateway, `ShareDelivery` re-lists, checks the
key is still there, and **posts without opening the picker**. It then shows
a "Sent: *title* → obsidian" line over the dashboard. If the key has gone,
it falls back to the picker as today.

- **He gains:** the whole decision happens in the sheet, with no switch and
  one tap if the preselection is right. Opening Latchkey later sends it,
  with nothing more to pick.
- **It costs:**
  - the mirror: a new file, written on every listing, which means one extra
    `GET /api/chat/slots` per foreground to keep it fresh;
  - a `destination` field on `ShareItem` (`version` 2, §7);
  - an auto-send path in `ShareDelivery` that skips the picker, which
    reverses F3 §6 answer 1 for pre-addressed items;
  - a revision to F3 §3's "the extension never picks a destination".
- **It cannot promise:**
  - **any delivery time.** Nothing is sent until he opens Latchkey, and if
    he never does, the 7-day sweep removes it (F3 §4.3);
  - **that the chosen session still exists.** The list is as of the last
    time the app was open, and the sheet shows its age;
  - **any word back.** He is not told when it goes out unless he opens the
    app, because notifications are off (F3 Q2, R34/D6);
  - "Sent" in the sheet. The sheet says **Queued**, never Sent.

### B — Session picked in the Shortcut, the app comes forward and sends

This is the stage-1 Shortcut with a `destination` parameter on
`SendToSessionIntent`. Its options come from a `DynamicOptionsProvider` that
reads the same mirror. The intent stays `.foreground(.immediate)`, so
Latchkey comes to the front and `ShareDelivery` sends straight to the chosen
key (after the re-list check) without showing the picker. He sees *Sent* in
Latchkey, and the dashboard moves to that session.

- **He gains:** a confirmed send, every time, with the session chosen before
  he leaves the sharing app. It is also the least new code: the intent,
  delivery and the foreground hand-off exist and are tested (F3 §7).
- **It costs:**
  - the switch, which he explicitly did not want;
  - the Shortcut's UI (a parameter prompt), not Latchkey's sheet;
  - the actions row, not the app-row icon;
  - the same mirror as A.
- **It cannot promise:** no switch. It also cannot promise a quick send: a
  cold node start before the post is seconds, and was ~66 s once (F3 §4.4).

### C — Background intent: picked and sent inside the share sheet

`SendToSessionIntent` declares `supportedModes = [.background,
.foreground(.dynamic)]`. Run from the Shortcut action, it shows the session
drop-down (the mirror, as in B) and then runs **in the app's process, in the
background**. It brings up the node if needed, delivers, and returns a
dialog: "Sent to obsidian" or "Queued: obsidian is mid-turn". If it cannot
finish, it chooses one of two ways out, per §9 Q3:

- it calls `continueInForeground` ("Open Latchkey to finish?"), which is a
  switch, but only on failure; or
- it leaves the item pre-addressed in the inbox, as in A, and says so.

- **He gains:** both halves of what he asked for, confirmed and with no
  switch, in the common case where the node is warm or starts quickly.
- **It costs, and each point needs measuring before building:**
  - **the budget.** iOS gives a background intent a limited, undocumented
    time. It has to cover node start (seconds cold, and ~66 s once), a page
    load and sign-in check, a re-list, an optional upload of up to 50 MB,
    and the post. First measure how long a `.background` intent in this app
    may run on the device;
  - **the page world in the background.** Delivery goes through the page's
    `fetch` in the web view (2.2). Nobody has measured whether a
    `WKWebView`'s content process loads and runs while the app has no
    foreground scene. If it does not, the only in-process route left is
    §4.9's `URLSession` with the cookie copied out of WebKit, which crosses
    R32. That is Olof's call, not an engineering default (§9 Q4);
  - the Shortcut UI and the actions row, as in B;
  - the mirror.
- **It cannot promise:**
  - **success from a cold node.** A cold start is the case most likely to
    miss the budget, and it happens after every relaunch;
  - **anything at all when a gateway needs sign-in.** The token sheet needs
    the app in front, so this always falls back;
  - **the app-row icon.** C exists only on the Shortcut route.

### Considered and not offered

| Route | Why not |
|---|---|
| The extension runs its own node | A new tailnet identity with its own login, tailnet-lock signature and dashboard sign-in; the Go runtime inside ~120 MB; a minute's cold start in a sheet (F3 §4.4, 2.1, 2.5) |
| The extension dials the app's loopback proxy | The app is suspended while another app's sheet is up. The proxy's credential is per launch, and the extension has no cookie (F3 §4.4, 2.2) |
| A background `URLSession` from the extension, to wake the app via `handleEventsForBackgroundURLSession` | This is a real, supported wake-up, but `nsurlsessiond` has no tailnet route. The upload would have to go to a non-tailnet host just to trigger the wake. That is a request off the tailnet whose purpose is a side effect, and the app wakes with the same background-budget and page-world unknowns as C. A hack on top of C, not an alternative to it |
| The official Tailscale app's system VPN gives the extension a route | Latchkey exists to not need it (`PLAN.md:57`). The phone would be a different node, so under `pin_scope: node` it needs a different sign-in, and there is still no cookie in the extension (2.2) |
| A local notification "tap to send" | F3 Q2 was decided no (R34/D6). A tap is still a switch. It is listed in §9 Q5 only because it would make A's "not delivered yet" visible |

## 5. What the owner sees

See the mock for all of these. Each column is one option, and each row is
one moment in the flow.

- **The sheet, drop-down closed.** A: the item, a Session row reading
  "obsidian · chonk ▾", a note, *Queue*. B and C: the Shortcut's prompt with
  the sessions listed.
- **The drop-down open.** The sessions, newest activity first, with folder
  and a running badge (the F3 §4.7 fields). The gateway is a section header
  when there is more than one known gateway. A footer reads "As of 14:02,
  when Latchkey was last open".
- **Empty list.** There are three cases, each in its own words:
  - no mirror yet (never opened since this update): "Open Latchkey once so
    it can list your sessions";
  - a gateway with no sessions: "chonk has no sessions";
  - a mirror older than the staleness limit (§9 Q6).

  In A the sheet falls back to today's *Save for Latchkey* (no destination),
  so nothing is ever refused for want of a list. In B and C the prompt is
  empty and the intent refuses with the same sentence.
- **Queued and not yet delivered.** In A's sheet: "Queued for obsidian on
  chonk. It will be sent when you next open Latchkey." The **next** share
  sheet lists what is still waiting and where it is going ("2 waiting:
  → obsidian 3 h, → notes 10 min"). In the app, Settings → Share shows each
  item's destination. When delivery runs, a "Sent 2 queued shares" line
  appears over the dashboard. C's fallback shows the same waiting state, or
  its `continueInForeground` prompt.
- **Failing** is F3 §2's table, plus one new row: the chosen session has
  gone by delivery time. A shows the picker with "The session you queued
  for, obsidian, isn't there any more — pick one." The item is never posted
  to the stale key.

## 6. Design sketch, common to all options

This is enough to cost the options, and is not yet buildable.

**6.1 The session mirror.** `App/Share/Inbox/ShareMirror.swift` (shared
source, like the inbox). It is written only by the app, as
`<group>/Library/Application Support/ShareMirror/mirror.json`, excluded from
backup:

```
{ version: 1,
  current: "<origin>",
  gateways: [ { origin, label, fetchedAt,
                sessions: [ { key, title, folder, running, lastActivity } ],
                lastDestination: { slotKey, slotTitle, at }? } ] }
```

- **When it is written:** after every successful `fetchSessions`, and after
  a cheap re-list on each foreground once the page is `.active`. The re-list
  is the one extra request.
- **When it is removed:** a gateway's entry goes when the gateway is removed
  from the workspace. The whole file goes on `-UITestResetShare`.
- **What it holds:** session titles and folder names. It holds no URL, note
  or content, and no credential. D1 is unaffected, because nothing leaves
  the device. The titles now sit in a container that two processes can
  read; it is still Latchkey's own container.

**6.2 `ShareItem.destination`** (A, and C's fallback): `{origin, slotKey,
slotTitle, chosenAt}?`. `ShareDelivery` treats a pre-addressed item as a
picker whose selection is already made:

1. re-list;
2. if the key is present, verify and post;
3. if not, the picker with the "queued for … isn't there any more" line.

It never posts the key unverified.

**6.3 `SendToSessionIntent`** (B, C): a `destination: ShareDestinationEntity?`
parameter, whose `EntityQuery.suggestedEntities()` reads the mirror. The
mode is `.foreground(.immediate)` for B and `[.background,
.foreground(.dynamic)]` for C. When the parameter is absent, the intent
behaves as today.

**Not to touch:**

- the split tunnel, `allowFailover`, ATS, D1 and R3;
- R32, unless §9 Q4 says otherwise;
- the extension still links no TailscaleKit;
- the inbox's write-last `item.json` and atomic rename.

## 7. State and migration

| What | Where | Previous version |
|---|---|---|
| The mirror | the group container, `ShareMirror/` | did not exist. A sheet with no mirror falls back to today's flow |
| `ShareItem.version` 2 with `destination` | the inbox | a v1 item has no destination and goes to the picker. F3 §5 says a higher `version` "is left alone and logged", so an older app build leaves v2 items unsent. Accepted: the extension and the app ship together |
| `share-defaults.json` | stays in the app container. The mirror copies `lastDestination` into the group container; it does not move the file | — |

## 8. Tests (sketch, per option)

- **Host:**
  - the mirror round-trips;
  - the staleness rule;
  - `destination` decode in v1 and v2;
  - `sessions(from:)` feeding the mirror.
- **Session suite:**
  - A: seed a pre-addressed item (`-UITestSeedShare … dest=obsidian`), then
    launch. Assert one post to `obsidian` with **no `share-picker` shown**.
    Then `/__slots?keys=notes`, seed again, and assert the picker with the
    "queued for" line, `violations` empty and `share_posts` unchanged. This
    is shown able to fail by posting the stored key without a re-list: the
    fake records a violation.
  - The mirror is written after a listing: read the group container with
    `simctl get_app_container … groups`.
  - The existing share-sheet test gains *choose a session*.
- **C:** the device only, and only after the budget measurement (§9 Q2). The
  simulator's background behaviour is not evidence for jetsam or budgets
  (M6).

## 9. Questions for Olof, ordered by how much they change the design

1. **Does the app-row icon matter, or would a Shortcut in the share sheet's
   actions list do?** If it must be the app-row icon, the answer is A:
   queued, never confirmed in the sheet (2.4), and B and C drop out. If the
   Shortcut will do, C is the only route to "confirmed, no switch", and B is
   its safe fallback.
2. **May I measure C before deciding?** This is a throwaway build, not
   shipped: a `.background` intent that logs how long it is allowed to run
   on the phone, whether a cold node reaches `Running` inside it, and
   whether the web view loads the dashboard while backgrounded. It takes
   about an hour on the device and turns C from a hope into a number.
3. **When a background send cannot finish, should it switch or queue?**
   Switching (`continueInForeground`) gets a confirmation at the cost of the
   switch he did not want. Queuing keeps the no-switch promise but gives no
   confirmation.
4. **If the web view does not work in the background, may delivery go
   around the page?** This means `URLSession` through the node's proxy with
   the dashboard cookie copied out of WebKit (F3 §4.9), which is the line
   R32 drew. If not, C is only as good as the page world is in the
   background.
5. **For A: is "queued, delivered when you next open Latchkey" enough with
   no signal back?** The alternative is a badge or a local notification
   saying something is still waiting. That reopens F3 Q2 (R34/D6: no
   notifications).
6. **How old can the cached list be before the sheet stops offering it?**
   My suggestion is 24 h, then the sheet says so and falls back to "pick in
   Latchkey". Also: should the drop-down offer every known gateway, or only
   the current one?
7. **Settle before building:** is there an SDK route for a share extension
   to perform an App Intent in its containing app? I found none (2.4). If
   one exists, C comes to the app-row icon and question 1 goes away. This is
   research, not a question for Olof; it is here because it could reorder
   the list.

## 10. Log

- 2026-09-25: options written from the code and the 27.0 SDK. Corrections to
  the framing: from the app-row extension the switch cannot be made for him
  at all (2.4). The "cached list" does not exist: the session list is held
  in memory only (2.3). A background-mode App Intent is the one supported
  way to run where the node is without a switch, from the Shortcut only
  (2.6). Nothing implemented; no suite run.
