# Feature specs

From 2026-09-23 Latchkey is no longer built from `../PLAN.md`. The plan's
milestones are done bar the owner-and-device items; what follows is driven by
Olof's requests and feedback, one spec at a time.

**The rule: spec first.** Every request — a feature, a change, a piece of
feedback — gets a document here before any code is written. Fine-grained:
someone who has not seen the conversation should be able to build it, and
should be able to tell afterwards whether it was built. Then it is
implemented, tested end to end, reviewed adversarially, and recorded in
`../DECISIONS.md` like everything before it.

**Tests are end-to-end.** A feature is done when a test drives the real app
against a real (fake-backed) tailnet and asserts what the owner would see.
Host unit tests are welcome where logic is pure, but they do not stand in for
a suite run. Every test must be shown able to fail — against the code before
the change, or by breaking it on purpose — and the spec says how.

| # | Feature | Status |
|---|---|---|
| [F1](F1-gateway-port.md) | A gateway carries a port; **443 stays the default** (R40, number deferred) | **partly built** 2026-09-27: a typed `host:port` is kept and a bad port refused; discovery probes 443 and 8443 and lists each as its own row; the sign-in sheet names the port. **Not built:** the origin check and its banner (§4a B), the fake gateway's `--allow-origin` (§4a C) and the session tests. A gateway on 8443 loads and then does nothing until the gateway allows the ported origin. 8443-as-standard stays deferred (§0) |
| [F2](F2-connecting-state.md) | A visible connecting state for a page load in flight | superseded by F4 |
| [F3](F3-share-into-a-session.md) | Share a link **or a document** from another app into a session on a gateway | designed; recommends stage 1 only (open item 1) |
| [F4](F4-never-a-bare-screen.md) | Never a bare screen: connecting, scanning and empty states | **built** 2026-09-24: connecting, holding and a rebuilt error page; three end-to-end tests for the connecting state |
| [F5](F5-portrait-session-list.md) | The instance chips collide in portrait (bug report) | **built** 2026-09-25 (R43): a gated stylesheet makes the chip row scroll, and Settings switches between known gateways. The rule applies in landscape too (since F9 the page is under 767 px there), and the pinned-chip test was dropped because it passed before the fix |
| [F6](F6-single-origin-web-view.md) | The web view loads the gateway, four named CDNs, and nothing else | **built** 2026-09-25 (R41); L1 38/38; session suite 33/33 against the real 0.7.1 bundle (§9) — the only load blocked is the Google Fonts stylesheet; `/sandbox-doc/` widgets not exercised there. Two §4.1 claims did not hold on iOS 26 (§9) |
| [F7](F7-portable-discovery.md) | Discovery works on someone else's tailnet, and never overstates what it checked | **built** 2026-09-24 — discovery suite 10/10; one open question with a measurement behind it (§8) |
| [F8](F8-node-start-failure.md) | A node that cannot start is a screen, not a crash | **built** 2026-09-25: a node start failure shows on the gate instead of trapping |
| [F9](F9-safe-area-insets.md) | The page is no longer drawn under the Dynamic Island (bug report) | **built** 2026-09-24 (§0): the web view is no longer drawn under the Dynamic Island |
| [F10](F10-the-suite-can-see-the-screen.md) | The suite can see the screen: geometry has no instrument here, so layout bugs reach the owner first (F5, F9) | **built** 2026-09-27. L1 sweeps our own chrome for unsafe regions and runs Apple's accessibility audit on the gate, dashboard, Settings, error page and picker, both orientations. The session suite asks the real page which of its drawn items collide, and that check catches F5 retroactively; the accessibility tree could not (no clipping or z-order for web content, §9). The audit's 37 first-run findings are a baseline, each an open owner item (§8) |
| [F11](F11-first-run-introduction.md) | The first screen says what this is and what is about to be asked of you (bug report: first run is a bare "Login" button) | **built** 2026-09-25: the gate introduces the app before first sign-in; adversarial review pending |
| [F12](F12-traceable-builds.md) | `make tf` refuses a dirty tree; the build records its commit (bug report) | designed; ready to build. Two builds were made from a dirty tree on the day it was reported, and neither artefact says so |
| [F13](F13-bottom-safe-area.md) | The bottom safe area: the code's comment and the measurement disagree | **built** 2026-09-24: the page takes back the 10 pt the NavigationStack re-applied, and is no longer padded twice with the keyboard up |
| [F14](F14-fast-suites.md) | The suites are too slow to iterate against (L1 254s, session 482s, full tier ~17min) | designed; **measure before optimising** (§4.1). The acceptance criterion forbids the obvious wrong answer: a run that is faster because it does less is a failure |
| [F15](F15-chrome-does-not-own-the-page.md) | Latchkey does not own the page's corners (bug report: the gear and the dashboard's bell collide) | **built** 2026-09-24 (B): the app bar owns the top edge, and stays hidden until a scroll up summons it; awaiting the owner's device check (§7.4) |
| [F16](F16-loopback-stalls.md) | A stalled loopback costs seconds, not a minute (issue #3) | **built** 2026-09-27. Stage 1 (bounded status, two-strike recovery): the picker leaves "Searching…" in 6.2 s, not about a minute. Stage 2: a bus watcher is installed only after its caller's staleness check. Stage 3: the SOCKS relay starts without blocking the main actor, and the first load waits for the proxy. Stage 4: fault 3 measured at about 1 s (-1009), fix declined |
| [F17](F17-hand-off-needs-a-tap.md) | Another app opens only from a tap (issue #2) | **built** 2026-09-25 (R42); L1 42/42. The issue's third citation was the wrong function, and `navigationType` cannot tell a tap from a script's `a.click()`: the signal is a trusted click from the app's own world |
| [F18](F18-send-from-the-share-sheet.md) | Finish the share inside the share sheet: pick the session there, no switch into Latchkey | **built** 2026-09-26 as option C (the Shortcut's background run, from the actions list) with B as its fallback (§10): the session drop-down reads a mirror the app writes, the run re-lists before it posts, and hands over to the app when it cannot finish. **Device run still owed** for the background budget and the page world (§9 Q2). Option A (the app-row icon) not built |
| [F19](F19-app-review-access.md) | An Apple reviewer can exercise the app (0.1 held by Beta App Review, 2.1 Information Needed: "a demo QR code or AR marker") | **options, not decided** (§5), with paste-ready review notes and replies per option (§6). The QR code is the last of six steps. The hard ones are a tailnet identity and a dashboard that stays reachable. Real KiroCrew's 5-minute link is a constant, so demo data needs the fake gateway. Internal testing needs no review (§5.0). Encryption declaration correct; iPad claimed but untested; the share extension lacks its own privacy manifest |
| [F20](F20-ipad-target.md) | Latchkey either supports iPad or stops claiming to | **exploration, nothing decided.** The archive claims `UIDeviceFamily [1, 2]` and installs natively on iPad, yet no suite has ever run there. First measurement (L1 on an iPad Pro 11-inch) in §9. iPhone Duo is noted as likely-similar but out of scope |
| [F21](F21-calm-cold-launch.md) | A cold launch arrives at the dashboard without flashing through screens (issue #4) | **built** 2026-09-26 (§4.4). Measurement overturned §1: none of our screens flashes; the KiroCrew shell ships `data-theme="dark"` and chooses its theme after boot, a quarter-second of dark on a light phone. A document-start `<style>` makes the unresolved shell paint nothing, so the launch colour shows until the page's own theme does. Measured 225 ms of dark before, none after; `CalmLaunchTests` holds it. Upstream report drafted (`../upstream/kirocrew-theme-flash.md`). Owner's confirmation on device (§7.5) outstanding |
| [F22](F22-gateway-row.md) | The app bar lists the remembered gateways as chips with the dashboard's health lights; one tap switches directly | **built** 2026-09-28 overnight (issue #6): chips in F15's summoned bar, lit by a direct probe of each remembered gateway; one tap switches. Product calls in §8 made without Olof; device look outstanding |
| [F23](F23-voice-input.md) | The dashboard's voice input works, and does not crash the app (issue #9) | designed (speculative): awaiting the crash log. No mic usage string and no capture decision today, so voice input cannot work either way; §1.4 maps the log to the fix |

## Still open, not yet answered

Three sequencing questions from 2026-09-23 have no answer yet, and no work
depends on guessing them:

1. **F3 scope** — stage 1 only (links via a URL scheme and an App Intent,
   reachable through a Shortcut), or both stages including the share-sheet
   extension? **The design pass recommends stage 1 only, now**, and corrects
   what this list said before: documents do *not* pull the App Group inbox
   forward, because an `IntentFile` from Shortcuts is delivered to the **app's
   own process**. The App Group is a stage-2 cost only — and it may not be
   available on a free Personal Team at all, which would block stage 2
   regardless (F3 §4.3).
2. **Build order** — F4 and F6 together in one reinstall, since both touch
   `App/Browser` and both need the device to matter?
3. ~~**GitHub** — two private repos, with Olof running the pushes?~~
   **Answered 2026-09-23: one private repo**,
   [olofj/latchkey](https://github.com/olofj/latchkey). The two
   repositories were collapsed into it, `app/` becoming a directory rather
   than a nested repository. Olof still runs the pushes — a policy here blocks
   the agent from pushing.

## Bugs

A bug is a report, not a spec, and it should cost Olof one message to file.

- **Where:** a GitHub issue on
  [olofj/latchkey](https://github.com/olofj/latchkey), templates in
  `../../.github/ISSUE_TEMPLATE/`. One repository now, so one tracker and no
  question about which. Until the first push lands, a message in the session
  does the same job and the issue is opened afterwards.
- **What a report needs:** what happened, which gateway and port, and any log
  lines. The app's own log is Settings → Diagnostics → Logs, the node's is
  Settings → Node log, and while the phone is plugged in and
  development-signed, both can be pulled with
  `xcrun devicectl device copy from --domain-type appDataContainer`. Evidence
  beats description: every fault the first device run turned up was identified
  from a log line, not from a description.
- **What happens then:**
  - a small, obvious fix goes straight to a commit that closes the issue, **with
    a test that fails without it** — the same rule as everything else here;
  - anything that changes behaviour, or needs a design, gets a spec in this
    directory first, linked from the issue;
  - either way the finding lands in `../DECISIONS.md` if it says something
    non-obvious about the system. A fault worth remembering is worth a
    paragraph.
- **Reproduce it in a suite where it can be reproduced.** The bar is not "a
  test exists" but "the test failed before the fix". Where a fault needs the
  phone (a real suspension, a real tailnet, jetsam), say so in the issue and
  test what can be tested; the device stays the place some things are only
  ever found.

## The shape of a spec

Copy [`TEMPLATE.md`](TEMPLATE.md). It asks for:

1. **What Olof asked for**, quoted, and the date.
2. **Why** — the failure or the gap, with evidence (a log line, a measurement,
   a device run) rather than an assertion.
3. **What the owner sees** when it works, and when each part of it fails.
4. **Non-goals**, so the thing has edges.
5. **Design** — files, types, functions, the actual names. Including what
   *not* to touch: the split tunnel, `allowFailover`, ATS, D1 (nothing leaves
   the device), and the vendored tree's one-change-per-commit rule.
6. **State and migration** — what is persisted, and what happens to a value
   written by the previous version.
7. **End-to-end tests** — which suite, what each asserts, and how each is
   shown able to fail.
8. **Acceptance criteria** — measurable, with the instrument named.
9. **Open questions and owner actions.**

A spec is a living document: it records what was decided while building, and
what turned out to be wrong. When it disagrees with `../PLAN.md`, the spec
wins.
