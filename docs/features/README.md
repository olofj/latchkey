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
| [F1](F1-gateway-port.md) | A gateway carries a port; 8443 is the standard one (R40) | spec |
| [F2](F2-connecting-state.md) | A visible connecting state for a page load in flight | superseded by F4 |
| [F3](F3-share-into-a-session.md) | Share a link **or a document** from another app into a session on a gateway | designed; attachments to fold in |
| [F4](F4-never-a-bare-screen.md) | Never a bare screen: connecting, scanning and empty states | spec |
| [F5](F5-portrait-session-list.md) | Reaching the session list in portrait (bug report) | decided: native switcher behind the gear |
| [F6](F6-single-origin-web-view.md) | The web view loads the gateway and nothing else (no Google Fonts) | decided; ready to build |

## Still open, not yet answered

Three sequencing questions from 2026-09-23 have no answer yet, and no work
depends on guessing them:

1. **F3 scope** — stage 1 only (links via a URL scheme and an App Intent,
   reachable through a Shortcut), or both stages including the share-sheet
   extension? Note that answer 2 to F3 (documents, not only links) pulls the
   App Group inbox forward regardless.
2. **Build order** — F4 and F6 together in one reinstall, since both touch
   `App/Browser` and both need the device to matter?
3. **GitHub** — two private repos (`latchkey`, `latchkey-app`), with Olof
   running the pushes (a policy here blocks the agent from pushing)?

## Bugs

A bug is a report, not a spec, and it should cost Olof one message to file.

- **Where:** a GitHub issue on the parent repo (both repos' faults, one
  tracker), templates in `../../.github/ISSUE_TEMPLATE/`. Until the repos are
  pushed, a message in the session does the same job and the issue is opened
  afterwards.
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
