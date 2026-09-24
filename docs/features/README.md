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
| [F1](F1-gateway-port.md) | A gateway carries a port; **443 stays the default** (R40, number deferred) | designed; the port *mechanism* is live work, 8443-as-standard is deferred (§0, §4a) |
| [F2](F2-connecting-state.md) | A visible connecting state for a page load in flight | superseded by F4 |
| [F3](F3-share-into-a-session.md) | Share a link **or a document** from another app into a session on a gateway | designed; recommends stage 1 only (open item 1) |
| [F4](F4-never-a-bare-screen.md) | Never a bare screen: connecting, scanning and empty states | designed; ready to build |
| [F5](F5-portrait-session-list.md) | The instance chips collide in portrait (bug report) | designed; two independent halves (CSS rule, gateway switcher) |
| [F6](F6-single-origin-web-view.md) | The web view loads the gateway, four named CDNs, and nothing else | designed; ready to build (CDN widgets allowlisted, fonts still blocked) |
| [F7](F7-portable-discovery.md) | Discovery works on someone else's tailnet, and never overstates what it checked | **built** 2026-09-24 — discovery suite 10/10; one open question with a measurement behind it (§8) |
| [F8](F8-node-start-failure.md) | A node that cannot start is a screen, not a crash | designed; ready to build. Extends F4 with one state (G7). Specced from the review's deferred finding, and found a **second** launch-path trap that fires earlier on the same fault |
| [F9](F9-safe-area-insets.md) | The page is no longer drawn under the Dynamic Island (bug report) | **decided, ready to build (§0)**. The measurements were right and the conclusion wrong: the frontend's `display-mode` guard states an assumption rather than a bug, and Latchkey is the unusual party for drawing a page edge-to-edge with no chrome |
| [F10](F10-the-suite-can-see-the-screen.md) | The suite can see the screen: geometry has no instrument here, so layout bugs reach the owner first (F5, F9) | designed; ready to build. Keystone is fixture parity — the fake dashboard is *more forgiving* than the shipped frontend, so a correct safe-area test in L1 would still have passed |
| [F11](F11-first-run-introduction.md) | The first screen says what this is and what is about to be asked of you (bug report: first run is a bare "Login" button) | designed; ready to build. F4 hardened this screen's *failure* states; its initial state was never treated as one needing words |
| [F12](F12-traceable-builds.md) | `make tf` refuses a dirty tree; the build records its commit (bug report) | designed; ready to build. Two builds were made from a dirty tree on the day it was reported, and neither artefact says so |
| [F13](F13-bottom-safe-area.md) | The bottom safe area: the code's comment and the measurement disagree | designed; low priority. Likely a one-line comment fix — F9 §0's reasoning says the page should not be under the home indicator either, which is what the layout already does |

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
