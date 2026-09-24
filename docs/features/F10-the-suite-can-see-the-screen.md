# F10 — The suite can see the screen

| | |
|---|---|
| **Status** | spec |
| **Requested** | 2026-09-24, by Olof, after reporting F9 from a device: "you should have been able to find that yourself. Test coverage miss, please introspect and come up with (high value and not just silly checkbox) test cases for these kind of issues." |
| **Revision** | none |
| **Touches** | `app/UITests/`, `testing/harness/dashboard.py`, `scripts/test-offline.sh`, `scripts/test-session.sh` |

## 1. Why

Two of the nine specs in this directory are layout bugs the owner found with his
own eyes on his own phone, and neither was findable by any suite:

- **F5** — the instance chips collide in portrait.
- **F9** — the page bleeds under the Dynamic Island.

That is a pattern, and the cause is a *good* rule with an edge nobody noticed.
`README.md` in this directory says: "Prefer server-side evidence (what the fake
dashboard or the harness saw) over reading the screen." That is right, and it is
why these suites do not flake. But it also means **nothing in this repository
asserts where anything is**, so a whole class of defect had no instrument at all.
Measured 2026-09-24:

```
$ grep -rn 'orientation\|landscape' app/UITests/            # (nothing)
$ grep -rn 'performAccessibilityAudit' app/UITests/         # (nothing)
$ grep -rn '\.frame\b\|minY\|maxY'  app/UITests/            # keyboard handling only
```

Frames are read only to decide where to tap and whether the chat input moved
(`LatchkeyUITests.swift:624`, `:666`, `:746`). Geometry is a means, never a
subject. Every suite runs portrait, on one simulator.

**And the fixture is more forgiving than the product, in the exact dimension of
the bug.** This is the finding that matters most, because it would have defeated
a *correct* new test written in the obvious place:

| | viewport meta |
|---|---|
| shipped frontend (`kiro_crew/static/dist/index.html:29`) | `width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no, interactive-widget=resizes-content, viewport-fit=cover` |
| fake dashboard (`testing/harness/dashboard.py:89`) | `width=device-width` |

The fake never asks for edge-to-edge, so it cannot be clipped by an island, so a
safe-area test in L1 would have passed against the broken app. A fixture simpler
than reality hides precisely the bugs that reach the owner.

## 2. What the owner sees

Nothing, when this works: he stops being the first to notice that something is
under the island, off the bottom of the screen, or clipped in landscape.

Failing: each check names the element and the obstruction, so a failure is
actionable without a screenshot — "`gateway-refresh` (x, y, w, h) intersects the
top unsafe region (0, 0, w, 59)".

## 3. Non-goals

- **No screenshot or snapshot diffing.** It fails for the wrong reasons — a font
  metric, an animation frame, a new OS — so it gets blanket-rebaselined on red,
  and a suite that is rebaselined on red launders regressions instead of
  catching them. Every check here is a computed number with a stated rule.
- **Not a device matrix.** The point is coverage of *geometry classes* (an
  inset-bearing top edge, a home indicator, both orientations), not of hardware.
- **Not auditing the page's internals as native elements.** A `WKWebView` is one
  element to XCUITest; the page's own layout is reachable only by asking the page
  (§4.1), which is the existing server-side-evidence idea pointed at geometry.

## 4. Design

Four checks, ordered by value per unit of maintenance. §4.2 is the keystone: it
is what keeps the other three honest.

### 4.1 The app must not lie to the page about its insets

Covered by **F9 §6** and not duplicated here: probe pages report their computed
`env(safe-area-inset-*)` and viewport height to the harness, and the test asserts
numeric equality with the device's real insets. Numbers, not pixels; it cannot
rot, and it catches the rotation and keyboard cases for free.

### 4.2 The fake must be no more forgiving than the product

A host test (`app/scripts/test-fixture-parity.swift`, run by `make test-policy`)
that reads **both** documents and fails when they disagree on the things that
change layout:

- the `viewport` meta's `viewport-fit` and `interactive-widget` values;
- whether the document uses `env(safe-area-inset-*)` at all.

Real source: the installed `kiro_crew/static/dist/index.html` — the same file
`scripts/test-session.sh` already pins a bundle version of, read and never run.
Skip with a clear message when it is absent, rather than passing quietly.

This is the check that would have made F9 findable *before* the device install,
and it keeps working when KiroCrew 0.7 changes its viewport: the suite tells us,
instead of the owner.

### 4.3 Nothing of ours may sit under a system obstruction

`app/UITests/SafeAreaAudit.swift`, a helper called at the end of existing flows
rather than a suite of its own:

```
assertNothingObstructed(app, exempt: [...])
```

For every hittable element belonging to the app's own chrome, assert its frame
does not intersect the unsafe regions, derived at runtime from the window's safe
area rather than hard-coded. Deliberate exemptions are named with a reason — the
web view itself is edge-to-edge by design (F9), so it is exempt and its *content*
is covered by §4.1 instead.

Runs in **both orientations**: rotate, re-assert, rotate back. Orientation is a
dimension over existing checks, not a second copy of the suite — F5 was a
portrait-only bug, and rotating for the geometry sweep alone costs seconds.

### 4.4 The system's own audit, for free

`app.performAccessibilityAudit(for: [.clippedText, .hitRegion, .elementDetection,
.contrast])` at the end of the same flows. Apple maintains the rules, so it
catches clipped labels, unreachable controls and too-small targets at near-zero
maintenance cost, including cases nobody here thought to write down.

It does **not** see inside the web view, which is exactly why §4.1 and §4.2 carry
the page's half. Findings that are genuinely intended get an explicit
`XCTIssue` suppression with a comment, never a blanket disable.

**Invariants this must not break** (see `../../app/AGENTS.md`): no change to the
split tunnel, `allowFailover`, ATS, or D1; no vendored-tree change.

## 5. State and migration

Nothing persisted. All checks derive from the running app and the two documents
in §4.2.

## 6. End-to-end tests

The deliverables here *are* tests, so this section is about how each is shown
able to fail — which for a test is the only evidence that it works.

| Test | Suite | Asserts | Shown to fail by |
|---|---|---|---|
| Fixture parity (§4.2) | `make test-policy` | The fake's viewport meta matches the real frontend's on `viewport-fit` and `interactive-widget`, and both use `env(safe-area-inset-*)` | Its current state: today's fake declares only `width=device-width`, so the check fails **before** the fake is fixed. That red is the proof, and fixing the fake is part of this work |
| Obstruction sweep (§4.3) | L1, portrait + landscape | No hittable chrome element intersects the top or bottom unsafe region | Temporarily exempting nothing and adding `.ignoresSafeArea()` to the gateway picker's toolbar: the refresh control lands under the island and is named in the failure |
| Accessibility audit (§4.4) | L1 | No `.clippedText` / `.hitRegion` findings in the gate, picker and settings flows | Setting a fixed narrow frame on the connecting-state label so its text clips: the audit reports it |
| Inset truthfulness (§4.1) | L1 | See F9 §6 | See F9 §6 — reverting `BrowserView.swift` makes the probe report `0px` |

## 7. Acceptance criteria

1. The fixture-parity check fails against today's `dashboard.py` and passes once
   the fake's viewport matches the product's — instrument: `make test-policy`.
2. With the fake corrected, the F9 inset test still fails against pre-F9 app code.
   If it does not, §4.2 did not actually close the gap — instrument: run both.
3. The obstruction sweep runs in both orientations in L1 and adds < 30 s.
4. Re-running the F5 scenario (portrait instance chips) with the sweep in place
   reproduces a failure on the code as it was before F5's fix — the honest test
   of whether this would have caught the *previous* one, not just the last one.

## 8. Open questions and owner actions

- Criterion 4 is the one that decides whether this is worth its keep. If the
  sweep cannot catch F5 retroactively, the design is aimed at the wrong thing and
  should be reconsidered rather than shipped for the sake of coverage.
- `performAccessibilityAudit`'s findings on an app nobody has audited before are
  unknown; the first run may be noisy. If it is, the answer is to fix or
  explicitly suppress each finding with a reason — not to narrow the audit types
  until it goes quiet.
- No owner action.

## 9. Log

Opened 2026-09-24, from Olof's observation that F9 should not have needed his
eyes.
