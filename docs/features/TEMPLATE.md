# F<n> — <short title>

| | |
|---|---|
| **Status** | spec / building / built / abandoned |
| **Requested** | <date>, by Olof: "<the ask, quoted>" |
| **Revision** | R<n> in `../PLAN-REVISIONS.md`, if it changes documented behaviour |
| **Touches** | <areas, e.g. App/Discovery, TSNet, the L2 harness> |

## 1. Why

The gap or the failure, with evidence: a log line, a measurement, a device
run, a review finding. Not "it would be nice".

## 2. What the owner sees

Working: the sequence of screens or behaviour, in his words rather than in
identifiers.

Failing: each way it can fail, and what is shown then. A silent failure is a
bug in the spec.

## 3. Non-goals

What this deliberately does not do, and where that line is.

## 4. Design

Files, types and functions by name, with the change in each. Enough that
someone else could write it.

**Invariants this must not break** (see `../../app/AGENTS.md`):
- the split tunnel decides what goes through the proxy; only tailnet hosts do;
- `allowFailover` stays false;
- ATS stays on with no exceptions; HTTPS only;
- D1: no app or node logs leave the device;
- a vendored-tree change is its own commit (R16).

## 5. State and migration

What is persisted, where, and what happens to a value the previous version
wrote. If nothing is persisted, say so.

## 6. End-to-end tests

Per test: the suite it belongs in, what it drives, what it asserts, and **how
it was shown able to fail**. Prefer server-side evidence (what the fake
dashboard or the harness saw) over reading the screen.

| Test | Suite | Asserts | Shown to fail by |
|---|---|---|---|

## 7. Acceptance criteria

Measurable, each with its instrument (an app log line, a harness journal, a
server-stamped report).

## 8. Open questions and owner actions

What is not decided, and anything only Olof can do.

## 9. Log

What changed while building, what turned out to be wrong, and the commits.
