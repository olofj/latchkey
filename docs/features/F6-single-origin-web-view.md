# F6 — The web view loads the gateway, and four named CDNs, and nothing else

| | |
|---|---|
| **Status** | **designed 2026-09-23; ready to build.** Revised the same day: Olof accepted an allowlisted CDN set, so the promise is "one origin plus four fixed hosts" (§4.1a) rather than "one origin" |
| **Requested** | 2026-09-23, by Olof: "no URLs or network fetches should be attempted in the built in web browser, they should go to the regular browser on the device. This might already be the case, not sure -- since the whole app is a web surface." |
| **Revision** | will need one: it tightens a documented invariant (R3's "exactly one destination") from navigations to every request, **and then names four exceptions to it** (§4.1a) — the revision must state both halves, or it records a promise the code does not keep. Number assigned when recorded |
| **Touches** | `App/Browser` (new `ContentRules.swift`, `BrowserViewModel`, `PageScripts`, `PageScriptSources`), `App/Settings` (one toggle, §4.1a), `App/Diagnostics` (three counters), `testing/harness` (`dashboard.py`, `Makefile`), the L1 offline and session suites, three host tests. `NavigationPolicy`, `TSNet/`, the split tunnel: untouched |

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
scripts, images, XHR, `EventSource`, WebSockets, workers and cross-origin
iframes (sub-frames are deliberately `.allow`ed, so the dashboard's same-origin
`/sandbox-doc/` widgets work).

**What that costs today, measured in the real 0.6.0 bundle**
(`kiro_crew/static/dist/index.html`, read 2026-09-23 — the earlier draft had
the shape slightly wrong):

```html
<link rel="preconnect" href="https://fonts.googleapis.com" />
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin />
<link rel="preload" as="style" href="https://fonts.googleapis.com/css2?family=Space+Grotesk…&family=JetBrains+Mono…"
      onload="this.rel='stylesheet'" />
<noscript><link href="https://fonts.googleapis.com/css2?…" rel="stylesheet" /></noscript>
```

So every dashboard load opens **two TLS connections to Google before any
stylesheet is asked for** (the preconnects), then fetches the CSS, then the
font files from `fonts.gstatic.com`. The server's own Content-Security-Policy
(`kiro_crew/dashboard/server.py:823-857`) permits exactly this and more:
`script-src`/`style-src` name `cdn.tailwindcss.com`, `cdn.jsdelivr.net`,
`cdnjs.cloudflare.com` and `esm.sh` (MCP apps and widgets pull their runtimes
from there), `img-src … https:` (any remote image), `font-src …
fonts.gstatic.com`. The split tunnel is working as designed when it lets all of
that go direct (none is a tailnet host), but it means:

- Google, and anything watching the phone's network, sees this device loading a
  KiroCrew dashboard, on a schedule that matches the owner's working day;
- the app's one-destination promise is true of the address bar it does not have,
  and not true of the traffic it actually emits.

Agent output can widen this: a remote image in a message, or a YouTube/Vimeo
embed (the bundle builds both), loads from wherever it points.

This is the same class of invariant as `allowFailover = false` and ATS-with-no-
exceptions, and it deserves the same treatment: enforced, and tested by
observing the other end.

## 2. What the owner sees

Working: the dashboard behaves as it does now, with **the system's own fonts**
instead of Space Grotesk and JetBrains Mono. Chat streams, sign-in works, the
sessions panel and the same-origin widgets render, downloads and "pop out
chat" still work.

A tapped link still opens in Safari, exactly as today. So does anything the
dashboard opens with `window.open`.

A remote image in agent output does not appear. In its place: a **44 pt dashed
box** the image's size or larger, which VoiceOver reads as "Image not loaded.
Tap to open in Safari." Tapping it opens the image in Safari (Olof's decision,
§3). A remote embed (YouTube, Vimeo) shows as an empty box with no marker.

**CDN-backed widgets and MCP apps do render** — Olof's decision of 2026-09-23,
after the design pass surfaced that they would not. Four fixed hosts are
allowed (`esm.sh`, `cdn.jsdelivr.net`, `cdnjs.cloudflare.com`,
`cdn.tailwindcss.com`), so an Excalidraw or PDF MCP app loads its ESM runtime
and works as it does on the desktop. What that costs, stated plainly because it
is the one place this feature deliberately leaks: **each of those four hosts
sees the phone's IP address and the fact that it is loading a KiroCrew
dashboard**, on the owner's working schedule — the same class of signal as the
Google Fonts leak this feature exists to close. The difference is that fonts
are cosmetic (the system's faces render fine) while a widget runtime is
load-bearing (the widget is blank without it), so the trade is worth making in
one case and not the other. §4.1a is where that line is drawn and defended.

**The font hosts stay blocked** even though the same CSP names them and the
allowlist could trivially include them. Blocking them is the evidence this
feature was built on, the upstream fix is already filed (KiroCrew#13161), and
nothing breaks without them.

Settings → Diagnostics → Page lists which of the four were actually contacted
this session, so the leak surface is visible on the device rather than implied
(§4.1a; it never leaves the device, D1).

Failing:

- **The filter cannot be built** (WebKit refuses to compile the rule list, or
  takes longer than 15 s): the app **does not load the page**. It shows F4's
  failed state — `nav-error-overlay`, with *Try again* and *Choose another
  gateway* — and the message: "Latchkey could not build the filter that keeps
  this page to its gateway, so the page was not loaded. [WKErrorDomain N] Try
  again, or choose another gateway." A single-origin promise that silently
  degrades to "everything allowed" is worse than no promise. While the filter
  is being built the screen is F4's connecting state, never bare.
- **The filter is wrong** (a future WebKit change to URL serialisation, say):
  the page's HTML loads and none of its own scripts or styles do — a blank
  dashboard. That is made diagnosable rather than mysterious: the marker
  script counts the gateway's own failed assets, the app logs
  `CONTENT-RULES: N of the gateway's own assets failed to load`, and Settings →
  Diagnostics → Page shows "Gateway assets failed: N". The bug-report rule in
  the README (a log line beats a description) applies.
- **The marker stops appearing** (a future bundle swallows `error` events):
  blocking keeps working, images simply vanish silently. The right way for the
  weaker half to fail, and a test pins it (§6).

## 3. Non-goals and the decided trade-off

- Not a content blocker in the general sense: one origin plus four compiled-in
  CDN hosts, ten fixed rules, **no list management and no "allow this origin"
  affordance anywhere in the UI**. The allowlist is a constant in the binary,
  not a setting with a text field — see §4.1a for why that distinction is the
  whole point.
- Not a change to sub-frame policy for *same-origin* frames: the dashboard's
  widgets (same-origin `/sandbox-doc/` iframes and `srcdoc` frames) keep
  working.
- Not the app's own network calls: discovery probes tailnet hosts only, and the
  node talks to control and DERP. Nothing else exists.
- Not DNS, not the OS's TLS revocation checks, not WebRTC (§4.2 names what a
  rule list cannot see; none of it is used by the 0.6.0 bundle).

**Remote images in agent output — decided 2026-09-23: a tappable marker.** A
blocked image shows a small marker that hands the URL to Safari when tapped, so
the promise holds and nothing is more than one tap away. Not blocked silently
(the owner would not know an image was there), and not allowed through (that
reopens exactly the tracking-pixel leak this feature closes). Note the page's
own CSP says `img-src 'self' data: blob: https:` — *any* https image — so the
rule list, not the CSP, is what stops a tracking pixel here.

**CDN runtimes for widgets — decided 2026-09-23: an allowlist of four fixed
hosts** (§4.1a). Not a wildcard, not owner-editable, not extended to the font
hosts.

## 4. Design

### 4.1 The rule list — and why the first draft's rule did nothing

The first draft's rule was
`{"trigger": {"url-filter": ".*", "unless-domain": ["<gateway host>"]}, "action": {"type": "block"}}`,
read as "block anything not on the gateway host". **That is not what
`unless-domain` means, and the rule as written would have blocked nothing.**
Checked in WebKit's source (`main`, read 2026-09-23):

- `ContentExtensionParser.cpp`, `loadTrigger`: `if-domain` and `unless-domain`
  are parsed by `getDomainList` and stored as the conditions
  `ActionCondition::IfTopURL` / `UnlessTopURL` — the **same** condition type
  as `if-top-url`. A domain condition is a condition on the **main document's
  URL**, i.e. the page the user is on, never on the resource being fetched.
  The WebKit blog that introduced them says it in one line: "It is possible to
  make a trigger conditional on the URL of the main document."
- `getDomainList` compiles each domain to the regex
  `[a-z][a-z+.-]*:\/\/` + (`([^/]*\.)*` only if the domain starts with `*`) +
  the escaped domain + **`[:/]`**. The trailing class means *any* port
  satisfies it: as far as a domain condition is concerned,
  `https://gw:8443/` and `https://gw:9999/` are the same place.
- `ContentExtensionsBackend.cpp`, `processContentRuleListsForLoad`: for a
  subresource, `mainDocumentURL = page->mainFrameURL()`, and the top-URL
  conditions are evaluated against that; the resource's own URL is matched
  only by `url-filter`.

So the draft rule meant "block every load **on any page other than** the
gateway's". The only page this app ever shows *is* the gateway's, so the rule
never fired and Google Fonts would have loaded exactly as today. (The L1 leak
test would have caught it on its first run — which is the point of §6 — but
the implementer would have lost a day to it.) The port question in the brief
is real but second-order: the draft was port-blind *and* inverted.

There is no "unless" form for the resource URL at all, and the URL-filter
dialect cannot express "everything except X": `URLFilterParser.h` lists
`Disjunction`, `Group` (non-capturing/named), `BackReference` and
`UnsupportedCharacterClass` as **parse errors**, so no alternation (`a|b`), no
lookahead, no `\d`; only `.`, `[a-z]` ranges, `?`/`+`/`*`, plain parentheses,
and `^`/`$` at the ends. The idiom is therefore **block everything, then
`ignore-previous-rules` for what is allowed** — an ignore rule discards every
earlier matched action for that load (`ContentExtensionsBackend.cpp`,
`actionsForResourceLoad`, "iterate in reverse order to properly deal with
IgnorePreviousRules").

**The list**, rendered here for the origin `https://gw.example.ts.net:8443`.
For a gateway on 443 the `:8443` is simply absent: WebKit serialises URLs
without a default port, and `GatewayAddress.origin(of:)` already produces that
canonical form (lowercase, default port dropped), which is the string the
builder takes.

```json
[
  {"trigger": {"url-filter": ".*"},
   "action":  {"type": "block"}},

  {"trigger": {"url-filter": ".*", "resource-type": ["top-document", "popup"]},
   "action":  {"type": "ignore-previous-rules"}},

  {"trigger": {"url-filter": "^https://gw\\.example\\.ts\\.net:8443/"},
   "action":  {"type": "ignore-previous-rules"}},

  {"trigger": {"url-filter": "^wss://gw\\.example\\.ts\\.net:8443/"},
   "action":  {"type": "ignore-previous-rules"}},

  {"trigger": {"url-filter": "^blob:"},
   "action":  {"type": "ignore-previous-rules"}},

  {"trigger": {"url-filter": "^about:"},
   "action":  {"type": "ignore-previous-rules"}}
]
```

**Four more `ignore-previous-rules` entries follow rule 1** — the CDN allowlist
of §4.1a. They are part of the same compiled list and are omitted here only to
keep the core readable; §4.1a gives them verbatim. Ten rules in total.

Why each rule is there, in order:

1. **Block every load of every type.** No `resource-type`, so a type WebKit
   adds later is blocked too: the list fails closed. `.*` is WebKit's
   "universal" pattern (`ParseStatus::MatchesEverything` is an optimisation,
   not an error).
2. **Top documents and popups belong to `NavigationPolicy` (R3), not to the
   list.** Two orderings force this exemption:
   - a main-frame **redirect** is re-checked against the list in
     `ResourceLoader::willSendRequestInternal` (with the redirect target as the
     URL) *before* `DocumentLoader::willSendRequest` asks the navigation
     delegate. Blocked there, it fails with `WebKitErrorDomain 104`
     (`blockedByContentBlockerError`), `decidePolicyFor` never sees the
     redirect, nothing goes to Safari, and `handlePolicyInterruption` (which
     knows only 102) paints the error page over the dashboard — R3 review
     finding 1 all over again. The existing redirect-away test fails without
     this exemption;
   - `window.open(url)` consults the list as `popup` inside
     `LocalDOMWindow::open` (`LocalDOMWindow.cpp`, the `#if
     ENABLE(CONTENT_EXTENSIONS)` block before `createWindow`) and returns
     `null` **before** `createWebViewWith` is ever asked. KiroCrew's 14
     `window.open` call sites would silently die and `PopupCatcher` would
     never run.
   `child-document` is deliberately **not** exempt: cross-origin iframes
   (YouTube/Vimeo embeds, `WebPreviewPanel`'s loopback frames) are blocked,
   which §1 wants. The type names come from `readResourceType`
   (`loader/ResourceLoadInfo.cpp`): `document`, `top-document`,
   `child-document`, `image`, `style-sheet`, `script`, `font`, `raw`,
   `websocket`, `fetch`, `other`, `svg-document`, `media`, `popup`, `ping`,
   `csp-report`; `load-type` is `first-party`/`third-party` and is by
   registrable domain (`ts.net` is on the public-suffix list, so two tailnet
   machines would count as first-party — unusable here).
3. **The origin, exactly:** scheme, host, port, then `/`. Anchored with `^`;
   `.` escaped (`\\.` in JSON); the trailing `/` is what stops
   `gw.example.ts.net.evil.example/` and `gw.example.ts.net:9999/` from
   matching — WebKit guarantees a `/` after the authority for http(s)/ws(s)
   URLs even when the page wrote none. `url-filter` is case-insensitive by
   default, which is fine: hosts are lowercase already.
4. **The dashboard's WebSockets.** The bundle opens
   ``new WebSocket(`${proto}//${location.host}/api/ws`)`` with `proto` =
   `'wss:'` under https (also `/api/ws/stt`), so the port rides along;
   the list sees it as `ResourceType::WebSocket`
   (`ThreadableWebSocketChannel.cpp`). Without this rule the page loads and
   never updates — the F1 §4a failure shape. Alternation `(https|wss)` is a
   compile error, hence two rules.
5. **`blob:` URLs are evaluated** — the backend's only scheme early-out is
   `resourceURL.protocolIsData()`. The bundle creates workers from
   `URL.createObjectURL` (its CSP says `worker-src 'self' blob:`) and object
   URLs for previews and downloads; rule 1 alone would kill them. A blob URL
   carries its creator's origin and cannot be fetched cross-origin, so the
   exemption widens nothing.
6. **`about:srcdoc` child documents are evaluated too.** The MCP-app widget
   frames are `srcdoc` iframes (the server's CSP comment says so). A substitute
   -data main resource still goes through `DocumentLoader::loadMainResource` →
   `CachedResourceLoader::requestMainResource`, which runs the list with the
   URL `about:srcdoc` and type `child-document`; rule 1 alone would blank
   every widget. `about:blank` is loaded as an empty document
   (`maybeLoadEmpty`) and never evaluated; the rule names both so the
   invariant reads cleanly.

`data:` needs no rule: the backend skips it, so inline base64 images in agent
output keep working. A test pins that anyway (§6).

**The port matters, and rule 3 is what enforces it.** The origin, not the
host, is the unit: cookies are not port-scoped, so a subresource fetch to
another service on the same machine (a dev server the dashboard previews, a
second KiroCrew instance) would carry the dashboard's cookies; F1 keys the
session by origin; `NavigationPolicy` compares origins with the port. With
rule 3 anchored on `:8443/`, port 443 on the same host is a different string
and is blocked, and vice versa. `TailnetProxyPolicy` cannot help here — it
matches hosts, carries no ports (F1 §4), and only decides *how* a connection
leaves, never whether. A test proves the port is enforced (§6).

**Escaping.** The builder escapes with WebKit's own domain table
(`getDomainList`: `\ { } [ . ? * $`), leaving `/`, `:` and `-` literal. A
bracketed IPv6 origin (`https://[fd7a:…::1]:8443`) therefore escapes its `[`;
`]` alone is literal in this dialect. The host test compiles the exact output
on macOS WebKit, so a bad escape fails at `make test-policy`, not on the phone.

**Identifier and caching.** `WKContentRuleListStore` keys compiled lists by
identifier as a **file name** (`APIContentRuleListStore.cpp`,
`constructedPath`: `ContentRuleList-` + the encoded identifier), and
`lookUpContentRuleList` hands back whatever was compiled under that name
regardless of what the source says now. So:
- identifier = `latchkey.single-origin.v<schemaVersion>.<origin>`; bump
  `schemaVersion` whenever the template above changes;
- **always compile, never look up.** `compileContentRuleList` writes to a
  temporary file and `moveFile`s over the identifier's path, so a compile
  replaces a stale entry; ten rules compile in milliseconds; the in-memory
  `WKContentRuleList` is cached per origin for the process. The on-disk copy
  is a side effect, not something the app relies on;
- on success, remove other identifiers under the `latchkey.single-origin.`
  prefix (`getAvailableContentRuleListIdentifiers` + `removeContentRuleList`),
  ignoring errors. Old lists are harmless; this is hygiene.

### 4.1a The CDN allowlist — four fixed hosts, compiled in, and why not five

Olof's decision of 2026-09-23: *"I'm OK with an allowlisted set of URLs that are
allowed to be fetched."* This section is the set, the mechanism, and the limits
that keep an allowlist from becoming a general escape hatch.

**The set, taken from the gateway's own CSP, not invented.** `_BASE_CSP`
(`kiro_crew/dashboard/server.py:823-875`) names every off-origin host the
bundle is designed to use. Read directly, it gives:

| Host | Named in | What needs it |
|---|---|---|
| `esm.sh` | `script-src`, `style-src`, `font-src`, `connect-src` | MCP-app ESM runtimes (React, `@excalidraw/…`) imported by `srcdoc` widget frames via importmap — the server's own comment cites the real Excalidraw and PDF apps |
| `cdn.jsdelivr.net` | `script-src`, `style-src` | widget runtimes |
| `cdnjs.cloudflare.com` | `script-src` | widget runtimes |
| `cdn.tailwindcss.com` | `script-src`, `style-src` | widget styling (`/vendor/tailwindcss-browser.js` is the self-hosted twin, `token_auth.py:423`) |
| ~~`fonts.googleapis.com`~~ | `style-src` | **excluded.** Cosmetic; upstream fix filed as #13161 |
| ~~`fonts.gstatic.com`~~ | `font-src` | **excluded.** Same |
| ~~`*.cloudfront.net`~~ | `frame-src` | **excluded** — a wildcard over a whole CDN provider, and a different feature (deployed-artifact previews). §8 asks whether Olof wants it |

Four hosts. Every one is an **exact host**, no wildcard, which matches CSP
host-source semantics (`https://esm.sh` does not admit `evil.esm.sh` either) —
so the app is no more permissive than the page it is protecting.

**The rules**, appended after rule 1 of §4.1:

```json
  {"trigger": {"url-filter": "^https://esm\\.sh/"},
   "action":  {"type": "ignore-previous-rules"}},

  {"trigger": {"url-filter": "^https://cdn\\.jsdelivr\\.net/"},
   "action":  {"type": "ignore-previous-rules"}},

  {"trigger": {"url-filter": "^https://cdnjs\\.cloudflare\\.com/"},
   "action":  {"type": "ignore-previous-rules"}},

  {"trigger": {"url-filter": "^https://cdn\\.tailwindcss\\.com/"},
   "action":  {"type": "ignore-previous-rules"}}
```

Four properties of that shape, each of which a test pins (§6):

1. **`https://` is literal, so plaintext is still blocked.** `http://esm.sh/`
   does not match and ATS (R28) would refuse it anyway — belt and braces, and
   an allowlist that admitted `http` would be a downgrade channel.
2. **The trailing `/` is load-bearing**, exactly as in rule 3.
   `^https://esm\.sh/` does not match `https://esm.sh.evil.example/pwn.js`,
   because after the escaped host the next character must be `/` and there it
   is `.`. Nor `https://esm.shady.example/`. This is the prefix attack the
   naive `^https://esm\.sh` would hand over, and it is the single most
   important character in this section.
3. **Only the default port.** WebKit serialises `https://esm.sh/x` with no
   port, so a URL written `https://esm.sh:8443/x` keeps its `:` and fails the
   `/` match — blocked. An allowlisted host cannot be used to reach an
   arbitrary service on that host.
4. **No `resource-type` restriction.** The CSP admits these hosts for scripts,
   styles, fonts and `connect-src` in varying combinations; encoding that
   matrix in the rule list would add four more rules and a maintenance
   obligation to track their CSP, to prevent nothing — a host trusted for
   script execution is not meaningfully more trusted for a stylesheet.

**Compiled in, not configurable — and that is the design, not laziness.** The
allowlist is `ContentRules.allowedCDNHosts`, a `static let` array of four
strings in `App/Browser/ContentRules.swift`. There is no Settings text field, no
"allow this origin" prompt, no persisted list, and no way for a page to add to
it. The reason is the one already in §8: a runtime-editable allowlist is a hole
with a UI on it, and the interesting attack is not "the owner types a bad host"
but "something convinces the owner to type a bad host". A constant in the binary
changes only in a commit, with a review and a test.

**One toggle, because the strict promise must remain reachable.** Settings →
Privacy gains *Allow widget CDNs*, default **on** (Olof's decision). Off
recompiles the list without those four rules, giving the original one-origin
behaviour. The toggle's state is part of the rule-list identity, so it joins the
identifier: `latchkey.single-origin.v<schemaVersion>.<cdn0|cdn1>.<origin>`.
Without that, flipping the toggle would leave a stale compiled list under the
same name — the identifier-as-file-name trap §4.1 already documents.

**The owner can see what was actually fetched.** An allowed CDN load goes
*direct*, not through the SOCKS relay (`TailnetProxyPolicy` sends non-tailnet
hosts direct — that is why the fonts leak existed), so **the app cannot observe
it from the network side at all**: there is no CONNECT to journal. The only
on-device instrument is the page itself, so the marker script (§4a) gains a
reporter: after `load`, and on a 2 s debounce thereafter, it walks
`performance.getEntriesByType('resource')`, keeps entries whose origin is not
the gateway's, and posts the set of **origins** (never full URLs — a widget's
module path is not something to accumulate) to the app. `BrowserViewModel`
counts them per origin and Settings → Diagnostics → Page shows
"Off-origin hosts contacted: esm.sh (14)". It stays on the device (D1).

This is a page-script instrument, so it is as fragile as the marker and fails
the same way: if a future bundle breaks it the counter reads zero while the
blocking and the allowlist keep working. It is a **diagnostic, not an
enforcement point**, and §6 pins that distinction — no test may use it as
evidence that a block happened; the harness counters do that.

**What this section deliberately does not do:** it does not allow the font
hosts (§2), does not admit `*.cloudfront.net` (§8), does not widen `img-src`
back to `https:` (remote images keep the marker), and does not touch
`NavigationPolicy` — a *navigation* to `esm.sh` still leaves for Safari, because
rule 2 exempts top documents and the allowlist changes nothing about them.

### 4.2 What a rule list does not see — every hole named, with what covers it

| Load | Consulted the list? Where (WebKit `main`, 2026-09-23) | Covered by |
|---|---|---|
| `<img>`, CSS `url()`, `<link rel=stylesheet>`, `@import`, `<script>`, `@font-face`, `<link rel=preload/modulepreload/prefetch>`, `<object>/<embed>`, manifest | yes — `CachedResourceLoader::requestResource` | rule 1 |
| `<video>/<audio>` | yes — element-level check (`ResourceType::Media`) before the media player is handed the URL | rule 1 |
| `fetch`, XHR, `EventSource`, `sendBeacon`, `<a ping>`, CSP reports | yes — `CachedResourceLoader` (`fetch`/`other`) and `PingLoader` → `processContentRuleListsForPingLoad` | rule 1 |
| WebSocket (`wss:`) | yes — `ThreadableWebSocketChannel.cpp`, `ResourceType::WebSocket` | rule 1; rule 4 lets the gateway's through |
| Dedicated `Worker` script, its `fetch`/`importScripts` | yes — bridged to the document's loader (`WorkerThreadableLoader` → `DocumentThreadableLoader` → `CachedResourceLoader`) | rule 1 (+ rule 5 for blob-URL workers) |
| `SharedWorker` | believed yes, by the network process's copy of the list (`NetworkLoadChecker`); not read in source — **the L1 page pins it either way**: its shared worker fetches the away origin, and the count is the instrument | rule 1 |
| Service worker | **cannot exist here**: `WebPage.cpp`, `updatePreferences` — service workers are disabled unless the view limits navigations to app-bound domains, and the app declares no `WKAppBoundDomains` (`Latchkey/Info.plist`, checked). `navigator.serviceWorker` is undefined; the bundle's `navigator.serviceWorker.register('/sw.js')` is guarded by `'serviceWorker' in navigator` and inert. **Never add `WKAppBoundDomains` without revisiting this row** | n/a; the L1 page records it |
| Cross-origin `<iframe>` (embeds) | yes — `child-document` | rule 1; shows an empty box, no marker |
| Subresource redirect that starts on the gateway and ends elsewhere | yes — re-evaluated at each hop in `ResourceLoader::willSendRequestInternal` (`redirectFrom` = the previous URL); blocked → `blockedByContentBlockerError`. The first hop reaches the gateway, which is fine | rule 1 |
| Main-frame navigation, main-frame redirect | exempt on purpose (rule 2) | `NavigationPolicy` (R3) — the only authority, as today |
| `window.open` / `target=_blank` | exempt on purpose (rule 2) | `PopupCatcher` + `NavigationPolicy` |
| `<link rel="preconnect">` — **two in `index.html`** | in WebKit `main`: yes, `LinkLoader::preconnectIfNeeded` runs the list as `ResourceType::Ping` (also for `Link:` headers via `loadLinksFromHeader`). **Whether iOS 26's build has this is unverified.** A preconnect is a TCP+TLS handshake with the host in the SNI and no HTTP request, so the request counter cannot see it | rule 1 **if** present; otherwise **nothing** — not the proxy (the host is public, so it goes direct), not ATS. The L1 handshake probe decides (§6); if it fires, §8 |
| `<link rel="dns-prefetch">` | no — `prefetchDNSIfNeeded`, no check | **nothing**; a DNS query of the name only. The bundle has none; the harness cannot observe DNS |
| `data:` | never evaluated (backend skips `protocolIsData()`) | n/a — no network |
| `blob:`, `about:srcdoc` | evaluated | rules 5 and 6 |
| WebRTC (`RTCPeerConnection` → STUN/TURN), WebTransport | no — not HTTP loads; UDP ignores the SOCKS proxy | **nothing.** The bundle uses neither (0 hits in `dist/`). The L1 page reports `typeof RTCPeerConnection` and `typeof WebTransport` so a future bundle's use is noticed. A page-world `delete window.RTCPeerConnection` is defeatable and not proposed |
| OS-level: TLS revocation checks, captive-portal probes, system DNS | outside WebKit | out of scope; not attributable to the page |
| The app's own traffic (discovery, tsnet control/DERP) | out of scope (§3) | — |

Two things this table settles for the implementer: a `WKUserContentController`
is live — adding a list after the web view exists takes effect for every load
that starts afterwards, and WebKit's in-order IPC means there is no callback
to wait for between `add` and `load`; and a `PopupCatcher`'s throwaway view is
built from a configuration that shares the parent's controller, so it carries
the same list and needs nothing.

### 4.3 `ContentRules.swift`, and the load path that waits

**`App/Browser/ContentRules.swift`** (new; `App/` is a synchronized group, no
project edit). Two parts, so the pure one is host-testable:

```swift
/// Pure Foundation. scripts/test-content-rules.sh compiles it alone.
enum ContentRules {
    static let schemaVersion = 1
    /// The four CDN hosts of §4.1a, in this order. Exact hosts, no wildcards,
    /// neither font host. Changing this list changes a promise: see §4.1a.
    static let allowedCDNHosts = ["esm.sh", "cdn.jsdelivr.net",
                                  "cdnjs.cloudflare.com", "cdn.tailwindcss.com"]
    /// The rules for `origin` (as GatewayAddress.origin(of:) renders it:
    /// lowercase, default port dropped), or nil if it is not http(s).
    /// Ten rules when allowCDNs, six when not.
    nonisolated static func json(forOrigin origin: String,
                                 allowCDNs: Bool) -> String?
    /// "latchkey.single-origin.v1.cdn1.<origin>" — the CDN flag is part of the
    /// identity, or flipping the toggle would reuse the stale compiled list.
    nonisolated static func identifier(forOrigin origin: String,
                                       allowCDNs: Bool) -> String
    /// WebKit's own domain escape table: \ { } [ . ? * $
    nonisolated static func urlFilterEscaped(_ s: String) -> String
}

@MainActor final class ContentRulesInstaller {
    enum State: Equatable { case none, compiling(origin: String), ready(origin: String), failed(origin: String, message: String) }
    private(set) var state: State = .none
    private var compiled: [String: WKContentRuleList] = [:]   // per origin, this process
    /// The compiled list for `origin`, from the per-process cache if present.
    func cachedList(forOrigin origin: String) -> WKContentRuleList?
    /// Compiles (always; never lookUp) with a 15 s deadline and caches.
    func list(forOrigin origin: String) async throws -> WKContentRuleList
}
```

`list(forOrigin:)` wraps
`WKContentRuleListStore.default().compileContentRuleList(forIdentifier:encodedContentRuleList:)`
in a checked continuation; any error (`WKError.contentRuleListStoreCompileFailed`
is the expected one) or the deadline becomes `.failed` and rethrows. Test
hooks, both through `TestHooks.flag` inside `#if LATCHKEY_TEST_HOOKS` (R15):
- `-UITestBreakContentRules`: the JSON handed to the **real** compiler is
  `[{"trigger":{"url-filter":".*"},"action":{"type":"no-such-action"}}]`, so
  the failure path is WebKit's own, not a stub;
- `-UITestNoContentRules`: the installer reports `.ready` without adding any
  list. The positive control for every leak test, and nothing else.

**`App/Browser/BrowserViewModel.swift`.** `loadResolved(_:)` is already the
one place app-initiated loads pass through and the only writer of
`allowedOrigin` (R3). It becomes the choke point for the list as well.
**Invariant: whenever `webView.load` is called with an http(s) URL,
`installedRulesOrigin == allowedOrigin`, and both are written only here.** A
`assert` enforces it in Debug/Testing.

```
loadResolved(url):
  guard let origin = GatewayAddress.origin(of: url) else {
      webView?.load(url); return              // about:blank fallback, the bounce harness's
  }                                            // bounce-test: page — nothing to protect
  allowedOrigin = origin                       // as today
  loadGeneration += 1; let generation = loadGeneration
  if installedRulesOrigin == origin { load(url); return }
  if let list = contentRules.cachedList(forOrigin: origin) {
      install(list, origin); load(url); return // synchronous: no gap, no await
  }
  pageState = .connecting(host: url.host, since: .now)   // F4's state, entered a step early
  Task { await installThenLoad(origin, url, generation) }

installThenLoad(origin, url, generation):
  do {
      let list = try await contentRules.list(forOrigin: origin)
      guard generation == loadGeneration, let webView else { return }   // superseded: drop
      install(list, origin); load(url)
  } catch {
      AppDiagnostics.shared.contentRulesFailures += 1
      logger.log("CONTENT-RULES: compile failed for the gateway: \(LogRedaction.describe(error))")
      navigationError(error, for: url)         // F4's .failed: nav-error-overlay, Try again, Choose another gateway
      navErrorKind = .other
      navErrorMessage = "Latchkey could not build the filter that keeps this page to its gateway, so the page was not loaded. [\(domain) \(code)] Try again, or choose another gateway."
  }

install(list, origin):                          // one synchronous run on the main actor
  let controller = webView.configuration.userContentController
  controller.removeAllContentRuleLists()
  controller.add(list)
  installedRulesOrigin = origin
  logger.log("CONTENT-RULES: installed for the gateway (schema v\(ContentRules.schemaVersion))")
```

Points the implementer will otherwise trip on:

- **Where the wait lives.** `makeWebView()` runs inside SwiftUI's `makeUIView`
  and is synchronous; it calls `loadResolved`, which must not block. The first
  compile per origin per process is the only asynchronous case; every later
  load — the startup retries (`retryStartupLoadIfAppropriate` →
  `loadResolved`), `loadSessionURL`, `loadGatewayIfRecovered`,
  `recoverFromContentProcessTermination`'s `loadResolved`, a re-created view
  after `unloadWebView` — finds the list in the cache and installs it
  synchronously. `webView.reload()` and `routeNewWindow`'s same-origin load
  need nothing: the controller re-sends its lists to a new content process,
  and same-origin is the installed origin.
- **F4 owns the states; F6 enters one of them early.** F4 derives
  `.connecting` from the provisional navigation; F6 sets it at `loadResolved`,
  because the compile precedes the provisional callback. From there F4's
  transitions are unchanged (`.painted` on commit, `.failed` where
  `navigationError` runs, the hint at 6 s). The failed state is F4's overlay
  with F4's actions; F6 adds only the message. If F6 is built before F4, it
  adds `pageState` with exactly F4's case names and identifiers
  (`page-connecting`, `nav-error-overlay`, `nav-error-choose-gateway`) and F4
  extends it. Recommendation for the README's open question 2: **build F4 and
  F6 together.**
- **Coalescing.** `loadInitial` is re-entered on every `$localStatus`/`$state`
  publication, and `loadGatewayIfRecovered` can race a startup retry. While a
  compile is in flight for the same origin, a later `loadResolved` bumps
  `loadGeneration`; the pending task loads only if its generation is still
  current, so exactly one load starts, and it is the latest.
- **`unloadWebView()`** clears `installedRulesOrigin` (the next `makeWebView`
  brings a new configuration and controller); the compiled list stays cached.
- **WebKitErrorDomain 104 never reaches the main frame** while rule 2 stands.
  Do not teach `handlePolicyInterruption` about 104: if it ever appears, the
  exemption was dropped, and the redirect-away test is the alarm.
- **A wrong allow rule is diagnosable.** With `top-document` exempt, the
  gateway's HTML loads and its assets do not; F4 sees a commit and says
  `.painted`; the screen is blank. The marker script (4a) counts `error`
  events on the gateway's own `script`/`link`/`img` elements and posts the
  count once per document; the app logs `CONTENT-RULES: N of the gateway's own
  assets failed to load` and increments `AppDiagnostics.gatewayAssetFailures`.
  Settings → Diagnostics → Page gains "Off-origin loads blocked" and "Gateway
  assets failed" (counts only, page-reported, images/scripts/styles — `fetch`
  failures are invisible to a document listener, and the row says so).
- **Logging and D1.** The identifier embeds the origin; it is never logged
  raw. Log lines say "for the gateway". The URL a tapped marker hands out is
  logged through `redactedForLog`, like every navigation the policy sends out.

**Not touched:** `NavigationPolicy` (it keeps its half unchanged), `TSNet/`
and `TailnetProxyPolicy` (the split tunnel still decides *how* the gateway's
connections leave; blocked loads never reach it), `allowFailover`, ATS,
`SocksLogProxy`. Nothing here writes to disk except WebKit's own store.

### 4.4 Gateway switching: no load can start against the old list

How a switch happens today, read from the code: `Workspace.swift:163-164` —
`session.reset()` then `tabManager.reopenHomeTab()`, which calls
`unloadWebView()` on every tab (`stopLoading`, delegates nil, view released),
removes them, and opens a new `BrowserTab` → a new `BrowserViewModel` with the
new `initialURL` → SwiftUI installs it → `makeWebView()` → a **new**
`WKWebViewConfiguration` and controller → `loadInitial` → `loadResolved`, the
choke point. Sign-out (`Workspace.swift:204-205`) takes the same path.

So the sequence needs no new teardown: the old list lives in a controller
whose only web view has been stopped and released; the new view cannot issue
its first load before its own list is installed, and the per-origin cache is
immutable per entry, so nothing is shared mutably between the two view models.
The `about:blank` fallback (`HomePageAvailabilityChecker.unreachableFallbackURL`)
installs nothing — an empty document fetches nothing — and the recovery load
that follows it goes through the choke point like any other.

Within one view model, `allowedOrigin` can only change in `loadResolved`, and
the same call changes the list first. The order in `install` — remove, add,
load, one synchronous run — is what keeps the window between "old list gone"
and "new list in" at zero; a compile failure for a new origin leaves the old
list in place and no load starts (F4's failed state shows; the previous page,
if any, stays under it, exactly as any failed load today).

### 4.5 Script coexistence with F5 and the session bridge

What `makeWebView` installs today, in order: `PageScripts.install` (R2's token
strip; page world; main frame only), `session?.install` (the bridge; world
`latchkey-session`; main frame; handler `kiroSession` in that world only), then
`configureWebView?` (the bounce harness). Rules for F5 and F6, so they cannot
clash and cannot remove each other:

- **Worlds.** F6's marker script runs in its own isolated world,
  `WKContentWorld.world(name: "latchkey-blocked")`, and its handler
  `kiroBlocked` is added in that world only, like the session bridge. The page
  — and every sandboxed widget frame inside it — therefore cannot post to it.
  The DOM and its events are shared across worlds, so a listener in an
  isolated world still sees `error` and `click` on the page's elements, and a
  `<style>` it appends is the page's. F5's CSS may run in any world; it touches
  only the DOM.
- **Names.** Element ids `latchkey-<feature>-<purpose>`: the bridge's
  `latchkey-session-banner-hidden` exists; F6 adds `latchkey-blocked-marker`;
  F5 uses `latchkey-chips-wrap`. The attribute is `data-latchkey-blocked`
  (the earlier draft said `data-kiro-blocked`; aligned to the prefix). Handler
  names are unique across worlds anyway: `add(_:contentWorld:name:)` with a
  duplicate (world, name) throws `NSInvalidArgumentException`, and
  `makeWebView` is the only installer, once per configuration.
- **Order.** In `PageScripts.install`: R2 token strip, F5 chips, F6 marker;
  then the bridge. The order is documented there and does not matter
  functionally — each is an IIFE, F6's sees no page globals at all — but a
  fixed order is one less thing to wonder about.
- **Removal.** No code path removes a user script at runtime: the only API is
  `removeAllUserScripts()`, which removes everything (the M1 finding, when it
  wiped R2's and R3's scripts), and it stays banned. Rule lists are a
  separate collection: `removeAllContentRuleLists()` touches no script, and is
  called only inside `install`, immediately followed by `add`. "Removing one
  does not remove the other" holds by construction.
- **Frames.** The marker script is injected with `forMainFrameOnly: false` —
  the one exception `PageScripts`' header asks to be justified: agent images
  render inside the same-origin widget iframes, which is exactly where a
  marker is needed. The native side checks `message.frameInfo.securityOrigin`
  (protocol, host, port) against `allowedOrigin` with the existing
  `SessionManager.matches(_:_:)`; same-origin sub-frames pass, anything else is
  dropped and logged. A sandboxed `srcdoc` frame has an opaque origin, so
  **inside an MCP-app frame the marker draws but the tap does nothing** —
  accepted and named.
- **CSP.** The real server sends `style-src 'self' 'unsafe-inline' …`
  (`server.py:855`), so an injected `<style>` is allowed — the session bridge
  already depends on it; `srcdoc` frames inherit the header. The marker's CSS
  uses **no URL** (no `data:` glyph), so it depends neither on `img-src` nor
  on how the rule list treats `data:`. The fake gateway sends no CSP, so the
  session suite cannot catch a CSP regression; this paragraph is the record.

## 4a. How the marker works

A content rule list blocks silently: the page never learns why, and the app
never sees the request. So "show a marker" needs a mechanism, and the obvious
one — inject a marker element next to the image — fights React, which
reconciles an injected sibling away on the next render.

`PageScriptSources.blockedMarker` (source text, host-tested under Node like the
bridge), a `WKUserScript` at document start, every frame, world
`latchkey-blocked`:

- A **capture-phase** `error` listener on `document` (`error` does not
  bubble). For an `HTMLImageElement` whose resolved `src` is http(s) and whose
  origin differs from `location.origin`, it sets `data-latchkey-blocked="<absolute url>"`
  and `aria-label="Image not loaded. Tap to open in Safari."` — two attributes
  on a node React already owns is the smallest possible intervention; if React
  re-renders the image, the load fails again and the listener sets them again.
  Same-origin failures on `img`/`script`/`link` are **counted, not marked**
  (4.3); off-origin failures on `script`/`link` are counted as blocked.
  Counts are posted once per document, debounced 1 s, as
  `{event: "counts", blocked: n, gatewayFailed: m}` — numbers, never URLs.
- A `<style id="latchkey-blocked-marker">` appended to `document.documentElement`
  at document start (before `<head>` exists; React owns `#root` only):
  ```css
  img[data-latchkey-blocked] { display: inline-block; min-width: 44px; min-height: 44px;
    box-sizing: border-box; border: 1px dashed currentColor; border-radius: 6px;
    background-color: rgba(127,127,127,.15); cursor: pointer; }
  ```
  `::before`/`::after` do not apply to replaced elements, hence a box, not a
  pseudo-element. `min-*` is what makes an `alt=""` image visible — WebKit
  renders a failed `alt=""` image at 0×0, and markdown renderers emit `alt=""`
  routinely; the L1 page has one of each. 44 pt is the tap-target minimum. A
  glyph is a follow-up: it would need a `data:` URL, which the CSP allows and
  the rule list never evaluates, so it is possible, not risky.
- A capture-phase `click` listener: `if (!e.isTrusted) return;` then the
  nearest `[data-latchkey-blocked]`; posts `{event: "open", url}` to
  `kiroBlocked`, and stops propagation so the page's own click handler (a
  lightbox) does not also fire for a marked image. `isTrusted` is what makes
  `el.click()` from page script a no-op; a real tap on an element the page
  decorated itself is equivalent to tapping a link, which R3 already sends to
  Safari.
- Native: a weak `WKScriptMessageHandler` in `PageScripts` (same shape as
  `WeakScriptMessageHandler`), frame-origin-checked (4.5); `open` → parse with
  `URL(string:)`, require `http`/`https`, hand to the view model's
  `openExternally` — the closure `TabManager` already supplies, the path
  `NavigationPolicy.openExternally` uses — logged as
  `Blocked image opened externally: <redacted>`; `counts` → the two
  `AppDiagnostics` counters and the log line in 4.3.
- Blocked **iframes** fire no `error` event, so embeds get no marker (§2).

The script is injected content, so it is the fragile part of this feature and
is marked as such: if a future bundle swallows `error` events, the marker stops
appearing while **the blocking itself keeps working**. That is the right way
for this to fail, and a test pins it (§6).

## 5. State and migration

**One persisted value:** *Allow widget CDNs*, default **true**. It goes in
`WorkspaceDefinition` as an optional `Bool`, written back through the
workspace's `onChange` like every other setting — **not** `UserDefaults`, which
this app does not use anywhere (`SettingsViewModel` reads and writes the
definition, and `BackupExclusion` notes the Keychain is unused too). Optional
so a definition written by an older build decodes with the key absent, which
reads as `true` and matches Olof's decision; an older build reading a newer
definition ignores the key.

**Optional is necessary but no longer sufficient (2026-09-23).**
`WorkspaceDefinition` now has a hand-written `init(from:)`, added because the
review found that *any* decode failure silently orphaned the tsnet node
identity. A new field is therefore only read if it is added to **`CodingKeys`
and `init(from:)`** — declaring it optional and relying on synthesis would
compile, decode nothing, and look exactly like a working upgrade. Add a row to
`app/scripts/test-workspace-store.swift` asserting the flag survives a round
trip and that its absence reads as `true`.

Because the value selects which rules compile, it is
part of the rule-list identifier (§4.1a), so flipping it recompiles rather than
reusing the previous list.

Nothing else in the workspace store. WebKit's store keeps
`ContentRuleList-<encoded identifier>` files under the app's Library — verify
the exact directory on the first simulator run (the R1 disk scan lists the
container) and confirm R5's `BackupExclusion` covers it (`Library/WebKit` is
already excluded; if the store lives elsewhere, add that directory to
`BackupExclusion`). The identifier embeds the gateway origin, which is a host
name the workspace file already holds, not a secret.

Migration: none; earlier builds installed no list. Old identifiers (another
gateway, an older `v<N>`, the other `cdn<0|1>`) are removed opportunistically
and are harmless if left. Changing the template without bumping `schemaVersion`
is the one way to ship stale rules — the host test asserts the identifier
carries the version and the CDN flag.

## 6. End-to-end tests

The instruments already exist in L1: the fake dashboard counts requests per
Host and lists paths with User-Agent, the stub proxy journals every CONNECT
with host **and port**, and the **away origin `dash.localtest.me:8443`** is
served by the same fake and reachable direct — the R10 positive control proves
a leak to it *would* succeed, so zero means something. Three additions to the
harness, all in the parent repo:

- **`dashboard.py`: `GET /single-origin`**, the F6 page. Off-origin references
  to the away origin, each under a distinctive `/f6/…` path so `paths` names
  the culprit: `<img>` (no `alt`), `<img alt="">`, an `<img>` inside a
  same-origin `<iframe src="/f6/inner">`, `<script>`, `<link rel=stylesheet>`,
  `<link rel=preload as=style onload="this.rel='stylesheet'">` (the Google
  Fonts shape), **`<link rel=preconnect>`**, `<iframe>`, `<video preload=auto>`,
  `<a ping>`, and in script `fetch`, `new EventSource`, `new WebSocket('wss://…')`,
  `navigator.sendBeacon`, a same-origin `Worker` and `SharedWorker` that each
  `fetch` the away origin, a same-origin `<img src="/f6/redirect-img">` that
  302s to the away origin, and the **port probe**: an `<img>` and a `fetch` to
  `https://dash.tail-scale.ts.net:8444/f6/port-probe`. Same-origin machinery
  that must keep working, each reporting: a `data:` image, a `blob:` image
  from a same-origin fetch, a `blob:`-URL worker, a `srcdoc` iframe that
  `postMessage`s to its parent, plus the page's own `/ws` and `/events`. Capability
  probes in the report: `sw` (`typeof navigator.serviceWorker`), `sw_reg`
  (the registration attempt's outcome), `rtc`, `wt`. And `blocked_marks`: the
  number of `img[data-latchkey-blocked]` in the document and its inner frame
  after 3 s. A `window.open` link to the away origin's inert `/away-target`.
- **`dashboard.py`: `/__state` gains `"handshakes": {sni: n}`** — an
  `sni_callback` on the TLS context counts ClientHellos by server name. This
  is the only instrument that can see a preconnect. `make check` gains a
  self-test: one connection with SNI `dash.localtest.me` increments it.
- **`Makefile`: `--map dash.tail-scale.ts.net:8444=127.0.0.1:$(DASH_PORT)`**
  so the port probe *would* be served if allowed, and for the session run
  `--map fonts.googleapis.com:443=127.0.0.1:9 --map fonts.gstatic.com:443=127.0.0.1:9`
  so a leaked attempt is journaled and dies on a closed loopback port,
  **never reaching Google**.
- **The CDN allowlist needs the same treatment, and must never reach the real
  CDNs.** Map all four of `esm.sh:443` and the three lookalikes
  `esm.sh.away.example:443`, `esm.shady.example:443`, `esm.sh:8444` to
  `127.0.0.1:$(DASH_PORT)`, so each *would* be served — and counted by Host —
  if the list allowed it. Only `esm.sh:443` may answer; the other three prove
  the anchoring. One allowlisted host is enough to test the mechanism; the
  other three entries are the same regex shape and are covered by the host
  test, which is cheaper than four more launches. `/single-origin` gains
  `<script src="https://esm.sh/f6/cdn.js">` (reporting `cdn: ok`), a
  lookalike `<script src="https://esm.sh.away.example/f6/pwn.js">`, and a
  `fetch("https://esm.sh:8444/f6/cdn-port")`.

The session suite launches with `-ProxyEverything` for F6's tests: the fixture
path honours it (`TSNetManager.proxyConfig(upstreamHost:…)` →
`proxyEverythingRequested()`), every connection the web view makes then passes
the stub, and the journal becomes a **complete connection log for the real
bundle**, preconnects included. Production's split tunnel is untouched; L1
keeps testing it.

| Test | Suite | Asserts | Shown to fail by |
|---|---|---|---|
| `testOffOriginLoadsNeverReachTheAwayOrigin` | L1 (`test-offline.sh`) | `/single-origin` on the gateway, wait for a report with `ws:open`; then `requests["dash.localtest.me"] == 0`; no `/f6/` path without a `Safari/` UA; journal has no CONNECT to `dash.localtest.me` and **none to `dash.tail-scale.ts.net:8444`** (the port); **`handshakes["dash.localtest.me"] == 0`** (the preconnect) — three named assertions | the next row is the permanent positive control; and today's build (no list): every count rises |
| `testWithoutTheRuleListTheAwayOriginIsReached` | L1 | same page with `-UITestNoContentRules`: `requests["dash.localtest.me"] > 0`, `/f6/img.png`, `/f6/fetch`, `/f6/frame` served, a CONNECT to `:8444` journaled, **and `handshakes["dash.localtest.me"] >= 1`**. If the last is 0 the preconnect probe is vacuous and the test fails saying so | run it without the hook: every assertion inverts. This is R10's shape: the instrument must be shown to see a leak |
| `testAnAllowlistedCDNIsFetchedAndItsLookalikesAreNot` | L1 | on `/single-origin` with the allowlist on: `requests["esm.sh"] > 0` and the report says `cdn: ok` (the script ran); **and in the same run** `requests["esm.sh.away.example"] == 0`, `requests["esm.shady.example"] == 0`, and no request or CONNECT to `esm.sh:8444`. One test, because the positive and the anchoring must hold simultaneously or the allowlist is not what it claims | dropping the trailing `/` from the allow regex: the lookalike is served and its count rises — this is the prefix attack of §4.1a(2) and the assertion that catches it. Dropping the CDN rules entirely: `cdn: ok` never reports |
| `testStrictModeBlocksTheAllowlistedCDNs` | L1 | relaunch with *Allow widget CDNs* off (`-UITestNoCDNAllowlist`): `requests["esm.sh"] == 0`, no `cdn: ok`, and every assertion of `testOffOriginLoadsNeverReachTheAwayOrigin` still holds — strict mode is the original promise, intact | an identifier that omits the `cdn0`/`cdn1` component: WebKit hands back the stale ten-rule list compiled under the same name and `esm.sh` is still fetched. This is the §4.1a identifier trap, and it is the only test that catches it |
| `testTheFontHostsStayBlockedWhileTheCDNsAreAllowed` | L1 + session (real bundle) | with the allowlist **on**: the font hosts' counters are 0 and their SNI handshake counts are 0, while `esm.sh` is > 0. In the session run the journal's CONNECT set contains no `fonts.*` | adding either font host to `allowedCDNHosts`: the counter rises. Pins §2's "the font hosts stay blocked" against a well-meaning future edit that treats the CSP as one list |
| `testThePageCannotWidenTheAllowlist` | L1 | `/single-origin` appends, at runtime, a `<script>` and a `fetch` for the away origin and for `esm.sh.away.example`; both counters stay 0. A page cannot add to a compiled list | nothing in the app — this is a property of the mechanism, so the test exists to catch a future "allow this origin" affordance being added (§8) without the spec being revisited |
| `testTheGatewaysOwnMachineryStillWorks` | L1 | report shows `ws:open`, an SSE tick, `data_img: ok`, `blob_img: ok`, `blob_worker: ok`, `srcdoc: ok`, `sw: undefined`, `sw_reg: unavailable`; the report itself arriving proves same-origin `fetch` | dropping rule 5: `blob_worker` never reports; rule 6: `srcdoc` never reports; rule 4: `ws` never opens; an allow regex without the port (or with `:443` written out) on the gateway: nothing but the HTML loads and `CONTENT-RULES: … own assets failed` appears in the log |
| `testFailedRuleCompileLoadsNothing` | L1 | `-UITestBreakContentRules`: `nav-error-overlay` within 10 s whose text contains "filter"; `requests["dash.tail-scale.ts.net"] == 0` and no CONNECT for it; log has `CONTENT-RULES: compile failed`; *Try again* keeps both at zero | a one-line sabotage, `load(url)` in the catch block: the count rises. Recorded in §9 when done |
| `testRedirectToAnotherOriginLeavesTheAppAndKeepsTheDashboard` (existing) | L1 | unchanged: Safari foregrounds, no error page, `/away-target` never fetched in-app | dropping `top-document` from rule 2: WebKitErrorDomain 104, error page, Safari never appears |
| `testWindowOpenToAnotherOriginStillOpensSafari` | L1 | tap the page's `window.open` link: Safari foregrounds; no in-app fetch of `/away-target` | dropping `popup` from rule 2: `open` returns null, nothing happens |
| `testBlockedImageShowsAMarkerThatOpensSafari` | L1 | `blocked_marks >= 3` (no-alt, `alt=""`, and the one inside `/f6/inner`); `app.webViews.images["Image not loaded. Tap to open in Safari."]` exists with a frame ≥ 44×44; the page's own `el.click()` and a page-world `postMessage` attempt produce **no** Safari within 5 s and no "opened externally" log line; then a real tap: Safari foregrounds and `paths` shows `/f6/img.png` only with a `Safari/` UA | no marker script: `blocked_marks == 0`; `forMainFrameOnly: true`: the inner frame's image is unmarked; dropping `isTrusted`: Safari appears on the synthetic click |
| `testTheRealDashboardConnectsToNothingButTheGateway` | session (`test-session.sh`), real 0.6.0 bundle, `-ProxyEverything` | after the existing sign-in reaches a live chat: the journal's CONNECT set is exactly `{gw.tail-scale.ts.net:443}` — no `fonts.googleapis.com`, no `fonts.gstatic.com`; and the `LOADED-PAGE` log line (`-UITestLogResponses`, extended with `fontsLinkRel` and `webFonts`) shows `fontsLinkRel: "preload"` (its `onload` never ran) and no Space Grotesk / JetBrains Mono face. Post-run grep in `test-session.sh`, like the R1 check | `testWithoutTheRuleListTheRealDashboardReachesForGoogle`: `-UITestNoContentRules` — the journal shows CONNECT `fonts.googleapis.com:443` and `fonts.gstatic.com:443` (dying on port 9, never leaving the machine). Permanent, like R10's control |
| The dashboard is undisturbed | session + F5 + F4 | the existing session tests, F5's chip tests and F4's "a painted dashboard never shows the connecting state" all run with the list installed — they are F6's regression net for "nothing else changes" | any of them failing after F6 lands |
| A ported gateway under the list (when F1 lands) | discovery (L2) | against `gw-alt` on 8443: the CONNECT set is `{…:8443}` only and the WebSocket opens (the page reports) | an allow rule built from the host alone |
| `test-content-rules.sh` | host (`make test-policy`) | `json(forOrigin:allowCDNs:)` for `https://gw.example.ts.net` (no port) and `:8443`; `.` escaped; an IPv6-literal origin escapes `[`; `http://` yields `ws://`; identifier carries `v1`, `cdn0`/`cdn1` and the origin; **10 rules with the allowlist on and 6 with it off**, the four CDN entries in the documented order, each anchored `^https://` and ending `/`; **then compiles the exact JSON with macOS WebKit's `WKContentRuleListStore(url:)`** in a temp store — pass = compiles; and asserts the `-UITestBreakContentRules` payload does **not** compile, so the compile check is not vacuous | a misspelled type (`"top-documents"`) fails to compile; an alternation `(https\|wss)` fails to compile; a CDN entry without its trailing `/` fails the shape assertion — all recorded once as evidence. If the CLI cannot use WebKit under the agent's sandbox, the same check moves into the simulator suite |
| `test-cdn-allowlist.swift` | host (`make test-policy`) | table-driven over the **regex semantics**, without WebKit: for each of the four hosts, that the emitted filter matches `https://<host>/x` and does **not** match `https://<host>.evil.example/x`, `https://<host>evil.example/x`, `https://<host>:8444/x`, `http://<host>/x`, or `https://sub.<host>/x`. The set is exactly the four hosts of §4.1a and contains neither font host nor any `*` | adding a fifth host without updating the expected set; emitting a filter without `^`; emitting one without the trailing `/` — each flips a single boolean |
| `test-blocked-marker.js` | host, Node | the exact injected text against a fake `document`/`location`/`webkit`: same-origin error → no attribute, counted; off-origin `img` error → attribute + label; `javascript:`/`data:` src → nothing; untrusted click → no post; trusted click on a marked image → `open` with the URL; click elsewhere → nothing; counts posted once | the script printed from a build without the fix |

L1's budget: ten new launches add roughly 150 s; raise the budget line in
`test-offline.sh` from 180 s to 360 s (it warns, not fails) and say why. Three
of the four allowlist tests reuse `/single-origin` unchanged, so the cost is
launches, not fixtures.

## 7. Acceptance criteria

- **Zero** requests, zero CONNECTs and zero TLS handshakes reach the away
  origin from a page that references it a dozen ways — `/__state.requests`,
  `/journal`, `/__state.handshakes` — and the positive control shows each
  instrument seeing a leak when the list is off.
- **The allowlist is exactly four hosts and admits nothing adjacent to them:**
  `esm.sh` is fetched; `esm.sh.away.example`, `esm.shady.example` and
  `esm.sh:8444` are not — `/__state.requests`, one run. The host test pins the
  set itself, so a fifth host cannot be added without a failing test.
- **Strict mode restores the original promise:** with *Allow widget CDNs* off,
  `requests["esm.sh"] == 0` and every single-origin assertion still passes —
  which also proves the compiled list is keyed by the toggle rather than
  reused stale.
- **The font hosts are blocked whether the allowlist is on or off** — their
  request counters and SNI handshake counts, in both modes.
- The same host on another port is refused: no CONNECT to `:8444` — the
  journal.
- The real 0.6.0 bundle's connection set under `-ProxyEverything` is exactly
  the gateway; the fonts link stays `preload` — the journal and the
  `LOADED-PAGE` log line.
- Sign-in, chat, `/__drop_ws` reconnect, the sessions panel and F5's chips work
  under the list — the session suite green.
- A compile failure loads nothing: zero requests to the gateway and F4's
  failed state on screen — `/__state.requests`, `nav-error-overlay`.
- Redirect-away and `window.open` still reach Safari — Safari in the
  foreground.
- The marker: present for `alt`-less, `alt=""` and in-iframe images; a
  synthetic click does nothing; a tap opens Safari — the accessibility tree,
  Safari, `paths` with the `Safari/` UA.
- The JSON compiles on macOS WebKit and the broken payload does not — `make
  test-policy`.
- On the device: after a dashboard session, Settings → Diagnostics → Page shows
  "Off-origin loads blocked" ≥ 1 (the bundle's font link alone yields one) and
  "Gateway assets failed" = 0. Direct (non-proxied) connections are **not**
  observable on the device — the relay journals proxied traffic only — so
  "zero" is measured in the suites, and the device shows the counters.

## 8. Open questions and owner actions

- ~~**Olof — acknowledge the cost:** CDN-backed widgets will not render.~~
  **Answered 2026-09-23: allowlist them** (§4.1a). Four fixed hosts,
  compiled in, default on, one toggle to go strict, font hosts excluded.
- **Open, and worth a deliberate answer: `*.cloudfront.net`.** The server's
  `frame-src` admits it for live previews of **deployed webapp artifacts**
  (`WebAppArtifactCard`/`WebAppThumb`), and the front end gates on the exact
  `<dist-id>.cloudfront.net` shape. It is excluded from the allowlist because it
  is the one wildcard in the CSP — admitting it trusts every distribution any
  AWS customer has ever created, which is a categorically weaker promise than
  four fixed hosts. **Recommend leaving it blocked** until the phone is actually
  used to preview a deployed artifact; a blocked preview frame is an empty box,
  not a broken dashboard. If wanted, the honest form is `^https://[a-z0-9]+
  \.cloudfront\.net/` (this dialect has no `\d`, and `[a-z0-9]+` at least
  forbids a further dot), plus the front end's own shape check — say so in a
  revision rather than widening §4.1a quietly.
- **Olof:** should blocked embeds (YouTube/Vimeo iframes) also get an
  "open in Safari" affordance? Iframes fire no `error`, so it is a different
  mechanism — a follow-up if wanted.
- **Only if the preconnect probe fires on iOS 26** (WebKit `main` checks
  preconnect; the shipped build may not): accept and document it until #13161
  lands (a handshake reveals the host name to the network, nothing more), or
  add a loopback blackhole proxy configuration for non-tailnet hosts — a
  split-tunnel change that needs its own spec and Olof's call. Not decided
  here.
- Should the app ever offer "allow this origin for this session"? It would be a
  hole with a UI on it; recommend not — and note that the allowlist of §4.1a is
  deliberately *not* this: a constant in the binary that changes in a reviewed
  commit is a different object from a text field the owner can be talked into
  filling. `testThePageCannotWidenTheAllowlist` exists to make that difference
  a failing test rather than a preference.
- Worth telling KiroCrew: a self-hosted dashboard that fetches fonts from Google
  is a privacy leak for every deployment, and the fonts could be served from the
  gateway. **Filed as KiroCrew#13161.**

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
- 2026-09-23, design pass, against WebKit's source and the real bundle:
  **the draft's `unless-domain` rule was inverted** (a condition on the page's
  URL, not the resource's) and port-blind (`[:/]`); replaced by block-all plus
  `ignore-previous-rules` for the exact origin, `wss:`, `blob:` and `about:`,
  with `top-document` and `popup` exempt so R3 stays the authority. Found
  along the way: `blob:` workers and `srcdoc` widget frames would have been
  blocked; `window.open` and main-frame redirects would have silently stopped
  reaching Safari; service workers cannot exist in this view (no app-bound
  domains); `index.html` has two preconnects the request counter cannot see,
  so the harness gains an SNI handshake counter; the server's CSP shows
  CDN-backed widgets will not render (§8). Nothing built yet.
- 2026-09-23, **revised on Olof's answer**: CDN-backed widgets are allowlisted
  rather than sacrificed. The set is the four fixed hosts the gateway's own
  `_BASE_CSP` names for widget runtimes (`dashboard/server.py:823-875`),
  **excluding both font hosts** — they are cosmetic, #13161 is filed, and they
  are the evidence this feature was built on — and excluding
  `*.cloudfront.net`, the CSP's one wildcard (§8 asks). Consequences recorded
  honestly: the promise is now "one origin plus four hosts", each of those
  hosts sees the phone's address and that it loads a KiroCrew dashboard, and an
  allowed load goes direct so **no network-side instrument in the app can see
  it** — the Diagnostics counter is a page-script reporter and is explicitly a
  diagnostic, not enforcement. The toggle joins the rule-list identifier,
  because otherwise flipping it would silently reuse the stale compiled list.
  Four new L1 tests, one new host test; the anchoring test (`esm.sh` yes,
  `esm.sh.away.example` no, in the same run) is the one that matters.
