# F5 — Reaching the session list in portrait

| | |
|---|---|
| **Status** | spec; one measurement outstanding before the option is chosen |
| **Requested** | 2026-09-23, by Olof (bug report): "the list of remotes on the top left isn't really visible on portrait mode phone. Works well on landscape. Not sure if it's fixable since it comes from the dashboard but it affects user experience." |
| **Revision** | depends on the option: C would need one (it adds app UI over the page) |
| **Touches** | `App/Browser` (page scripts or a native affordance), possibly `App/Session`; the session suite |
| **Tracker** | would be issue #1 once the private repos exist; this document is the record until then |

## 1. Why

The dashboard's layout is Tailwind's: the sidebar that carries the session and
remote-instance list belongs to the ≥ `md` (768 px) layout, and there is a
"Hide sessions sidebar" / "Hide sessions" control for it
(`kiro_crew/static/dist/assets/*.js`, with `md:hidden` / `md:flex` pairs in the
same bundle).

The phone's numbers explain the report exactly:

| Orientation | CSS width on iPhone 14 Pro | Tailwind band |
|---|---|---|
| Portrait | 393 px | below `sm` (640) — the narrow layout |
| Landscape | 852 px | above `md` (768) — the sidebar layout |

So this is not a Latchkey bug and not a KiroCrew bug: it is a desktop-first
dashboard viewed at 393 px. The app cannot wait for an upstream fix (Olof does
not control KiroCrew releases), but it is not powerless either — it already
injects page scripts in the page world (`PageScriptSources`, R22/R32).

(The 861 px media queries in the bundle are Excalidraw's, not the dashboard's.
Noted so no one designs around them.)

## 2. The measurement this spec is waiting on

What portrait actually does with the list — collapse it behind the toggle, or
render it too narrow to use — decides between the options. The session suite
already serves the **real KiroCrew 0.6.0 bundle** through
`testing/harness/fake_gateway.py`, so the answer is a screenshot away in both
orientations (`XCUIDevice.shared.orientation`), with no device needed. Do that
first; record it here.

## 3. Options

**A. Ask WebKit for the desktop layout.**
`WKWebpagePreferences.preferredContentMode = .desktop` on the dashboard's
navigation gives the page a desktop-width viewport (~980 px), so portrait gets
the sidebar layout, scaled down. One line, no injection, survives any bundle
change.
*Against:* everything becomes small in portrait, and text scaling is then the
owner's pinch — it trades one usability problem for another. It also sends a
desktop user-agent, which may change other behaviour on a dashboard that
adapts to touch.

**B. Override the viewport or the breakpoint from the app.**
Inject a stylesheet or a viewport `<meta>` in the page world, gated to the
chosen gateway's origin, to keep the list usable below 768 px.
*Against:* it depends on the bundle's class names and structure, which change
without notice; when it breaks it breaks silently. Precedent exists (R35 keeps
a client-side patch in reserve for #9399) but as a fallback, not a foundation.

**C. A native session switcher (recommended).**
The app lists sessions itself — `GET /api/chat/slots` in the page world, the
same call F3 needs — and navigates the web view to `/chat?sid=<key>`. The
switcher is the app's own UI, so it is legible in portrait by construction and
independent of the dashboard's layout.
*For:* it is **the same list F3 already has to build** for "share into a
session", so one picker serves both: choosing where a shared link goes, and
choosing which session to read. It also gives the app a sensible answer to
"where am I?", which the one-page design currently leaves to the page.
*Against:* it is app UI over a web page, and this app has deliberately no
chrome (PLAN §1.3: no tabs, no address bar). That tension is real and the spec
takes it seriously: the switcher must be **one affordance, not a permanent
bar** — reached from the existing gear or a single control, dismissed after a
choice. If it starts looking like a tab bar, it has gone wrong.

**D. Report it upstream and do nothing.** Honest about ownership, no help to the
owner. Worth doing *as well*, whichever option ships.

## 4. Recommendation

**C, with A measured first as a stopgap.** A is a one-line experiment that can
be tried tonight on the phone and either helps or does not; the measurement in
§2 will show. C is the durable answer, it shares its implementation with F3,
and it is the only option that does not depend on someone else's CSS.

Sequence: measure (§2) → try A on the device and keep it only if portrait stays
legible → build C together with F3's destination picker, with the switcher and
the share picker as one component.

## 5. End-to-end tests

| Test | Suite | Asserts | Shown to fail by |
|---|---|---|---|
| The session list is reachable in portrait | session (M4), real bundle | in portrait, the switcher opens, lists the gateway's sessions from `/api/chat/slots`, and choosing one navigates the page to that `sid` | the current build: nothing in portrait reaches the list |
| Choosing a session actually changes the page | session (M4) | after a choice, the fake gateway's journal shows the `/chat?sid=<key>` request, and the page reports the selected session | navigating without the `sid` |
| Landscape is not made worse | session (M4) | in landscape the dashboard's own sidebar still works and the switcher does not cover it | pinning the switcher as permanent chrome |
| Desktop content mode, if kept | session (M4) | with A enabled, the sidebar layout appears in portrait; a named check records the resulting CSS width so the legibility trade-off is on the record | asserting nothing and trusting the screenshot |

## 6. Acceptance criteria

- In portrait, the owner can see the sessions on the chosen gateway and switch
  between them without rotating the phone.
- The switcher is absent from the screen until asked for, and gone after a
  choice: no new permanent chrome.
- Landscape behaviour is unchanged.
- The session suite covers all of the above against the real bundle.

## 7. Open questions and owner actions

- **Answered 2026-09-23:** the switcher lives **behind the gear**. No new
  permanent affordance over the page; the gear is already there, and this keeps
  the one-page design intact. (Option C of §3 — the native switcher — is
  therefore the chosen approach.)
- Should it list remote instances as well as sessions, or only sessions? The
  bundle has remote-instance management ("Add remote instance", "Configured
  remote instances"); whether the app needs to mirror that is a separate ask.
- Worth reporting upstream regardless: a dashboard whose session list is
  unreachable below 640 px is a bug on any phone, not only in this app.

## 8. Log

- 2026-09-23: reported and diagnosed from the bundle's breakpoints. Portrait
  measurement outstanding; options A–D written; C recommended and deliberately
  shared with F3.
