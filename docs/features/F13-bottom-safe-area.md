# F13 — The comment says the page owns the bottom safe area; the measurement says it does not

| | |
|---|---|
| **Status** | spec |
| **Requested** | not requested — found by measurement while diagnosing F9, 2026-09-24, and split out so two different bugs do not share one spec |
| **Revision** | none |
| **Touches** | `app/App/Browser/DashboardRootView.swift`, `app/App/Browser/BrowserView.swift`, the L1 probes |

## 1. Why

`DashboardRootView.swift:213` applies `.ignoresSafeArea(.container, edges: .bottom)`
and explains itself: *"The page owns the full screen, including the bottom safe
area."*

That is false as measured. From the F9 instrumentation run
(`app/build/offline-logs/20260924-135534/unified.log`, steady state):

| | the web view's own | the window's | `BrowserView`'s slot |
|---|---|---|---|
| bottom inset | **0** | 34 | 34 |

The web view reports no bottom inset because it never reaches the bottom: its
slot ends 34pt above the screen edge, exactly the home-indicator inset. So the
page does *not* own the full screen, something above the web view is consuming
the bottom safe area, and the comment describes an intent that the layout does
not implement.

This is not the bug Olof reported — his was the top edge — and it is not urgent.
It is recorded because a comment asserting the opposite of what the code does is
how the next person reasons their way into a wrong fix. F9 nearly shipped a 124pt
overcorrection off exactly that kind of confident-but-wrong premise.

## 2. What the owner sees

Either nothing changes and the comment starts telling the truth, or the page
gains 34pt of height at the bottom. Which of those is right is §8's open
question, and it is a judgement about what the app should look like rather than
something a measurement settles.

Note that F9 §0 decided the *top* edge should be inside the safe area. If the
same reasoning applies at the bottom — a page that does not know it is on a phone
should not be drawn under the home indicator — then the current behaviour is
already correct and **only the comment is wrong**. That is the likely outcome,
and it would make this a one-line change.

## 3. Non-goals

- Not changing the top edge. F9 owns that.
- Not "making both edges edge-to-edge for symmetry". Symmetry is not a reason;
  F9 §0 gives the reason, and it points the other way.

## 4. Design

Two candidate outcomes, and the work is deciding between them rather than
implementing a predetermined one:

**A. The layout is right, the comment is wrong** (expected). Delete or rewrite
`DashboardRootView.swift:213`'s claim, and say what actually consumes the bottom
inset. Then add an assertion so it cannot drift again: the web view's frame
`maxY` equals the window's safe-area bottom.

**B. The layout is wrong and the intent was right.** Then find what is eating the
34pt between `.ignoresSafeArea(.container, edges: .bottom)` and the web view, and
decide whether the page should really extend under the home indicator — which F9
§0's reasoning argues against.

Start by finding out *why* the bottom inset is consumed: the modifier is on the
root, the web view is several containers down, and something between them is
claiming it.

**Invariants this must not break** (see `app/AGENTS.md`): no change to the split
tunnel, `allowFailover`, ATS or D1; no vendored-tree change.

## 5. State and migration

Nothing persisted.

## 6. End-to-end tests

The probe infrastructure exists already (`/__inset-cover`, `/__inset-plain`,
`/__inset-product` in `testing/harness/dashboard.py`; `f697cfe`, `42647c0`), and
F9 §0.2 adds a window-safe-area probe. This needs one more assertion, not new
machinery.

| Test | Suite | Asserts | Shown to fail by |
|---|---|---|---|
| The bottom edge is where the comment says | L1 | The web view's frame `maxY` equals the window's safe-area bottom (outcome A), or the screen's bottom (outcome B) — whichever §4 settles on | Restoring the other behaviour: the assertion reports both numbers and which one moved |

## 7. Acceptance criteria

1. `DashboardRootView.swift:213`'s comment and the measured layout agree —
   instrument: the L1 assertion above, plus reading the comment.
2. Whichever outcome is chosen is stated in §9 with the reason, so the next
   person does not re-open it from the comment alone.

## 8. Open questions and owner actions

- **Should the page extend under the home indicator?** Olof's call, and the same
  question F9 §0 answered for the top. His words there — "it doesn't know it's
  being rendered on a phone" — apply unchanged at the bottom, which suggests no.
  If that is his answer, this is outcome A and a one-line change.

## 9. Log

Opened 2026-09-24 from a measurement taken while diagnosing F9.

2026-09-24: the consumer is the `NavigationStack`, which re-applies the window's bottom safe area to its content regardless of the root's `.ignoresSafeArea`; at Olof's request the page now takes 10pt of the 34pt back (`DashboardContent.bottomReclaim`), ending 24pt above the edge, clear of the home indicator, asserted in `testInsetProbesReportWhatThePageIsTold`.
