# F12 — A build you cannot trace to a commit is not a build you can ship

| | |
|---|---|
| **Status** | spec |
| **Requested** | 2026-09-24, by Olof: "Don't allow `make tf` in a dirty checkout, only with full check-in. Build ID should also contain git SHA somewhere." |
| **Revision** | none |
| **Touches** | `app/scripts/testflight.sh`, `app/Latchkey.xcconfig`, the app's `Info.plist`, `app/App/Diagnostics/DiagnosticsView.swift`, `docs/TESTFLIGHT.md` |

## 1. Why

`make tf` archives whatever is on disk. Today it did that twice, and neither
build can be traced to anything:

- build `202609241812` was archived while `BrowserView.swift` and
  `RawWebView.swift` carried uncommitted safe-area instrumentation;
- the 22:22 export (`app/build/appstore/Latchkey.ipa`, 15,020,824 bytes) carried
  the same, and the worker that produced it had to warn in prose — "don't ship
  it" — because nothing in the artefact says so.

A build number of `YYYYMMDDHHMM` records *when* it was built, which is the one
fact nobody needs. Once a build is in TestFlight the only questions are "what is
in it" and "can I get that source back", and today neither is answerable.

The tester is the owner, so this has stayed survivable by memory. It stops being
survivable the first time a build reaches TestFlight, gets a bug report, and the
tree has moved on.

## 2. What the owner sees

`make tf` refuses a dirty tree before spending minutes archiving:

```
error: the working tree has uncommitted changes, so this build could not be
       reproduced from any commit:
         M app/App/Browser/BrowserView.swift
        ?? app/App/Browser/Experiment.swift
       Commit them, or run with UPLOAD=0 to export a throwaway build.
```

Settings → Diagnostics gains a row naming the commit the running app was built
from, next to the version and build number already there. That is the row you
read out when a TestFlight build misbehaves.

Failing: with `UPLOAD=0` a dirty tree is allowed — that path exists for
experiments and cannot upload anything — and the recorded commit is suffixed
`-dirty` so the artefact still tells the truth about itself.

## 3. Non-goals

- **No `ALLOW_DIRTY=1` escape hatch on the upload path.** An override that
  defeats the check is the check, deleted, with extra steps. `UPLOAD=0` already
  covers the legitimate case.
- **Not putting the SHA in the build number.** `CURRENT_PROJECT_VERSION` must
  stay a monotonically increasing, dot-separated numeric string: App Store
  Connect rejects anything else, and rejects a repeat. A hex SHA is neither
  numeric nor ordered. The timestamp stays; the SHA goes beside it.
- **Not a full provenance system.** No build manifest, no signing of metadata.
  One commit hash, in the artefact and on screen.

## 4. Design

### 4.1 Refuse a dirty tree

In `app/scripts/testflight.sh`, beside the existing guards and **before** the
archive, so it fails in a second rather than after minutes of `xcodebuild`:

```sh
DIRTY=$(git status --porcelain)
if [[ -n "$DIRTY" && "$UPLOAD" != 0 ]]; then …refuse, printing $DIRTY… fi
```

**Untracked files count, and that is not pedantry.** `App/` and `UITests/` are
Xcode *synchronized folder groups* (`PBXFileSystemSynchronizedRootGroup`, see
`app/AGENTS.md`): a `.swift` file dropped in either is compiled automatically,
with no project edit. So an untracked source file is *in the build* while being
in no commit — exactly the case the check exists to catch, and the one a
`--untracked-files=no` shortcut would miss.

Gitignored files (`app/.asc-key`, `app/.dev-team`, `build/`) are already invisible
to `--porcelain` and stay that way.

### 4.2 Record the commit

`git rev-parse --short=12 HEAD`, plus `-dirty` when §4.1 permitted a dirty
export. Passed to `xcodebuild` as a build setting (`LATCHKEY_GIT_SHA=…`),
surfaced through `Info.plist` as `LatchkeyGitSHA`, and read back with
`Bundle.main.object(forInfoDictionaryKey:)`.

It must be passed on the command line rather than computed in a build phase: a
script phase that shells out to `git` breaks archiving from a source tree without
a `.git` directory, and makes the build depend on the build machine rather than
on its inputs.

### 4.3 Show it

One row in `app/App/Diagnostics/DiagnosticsView.swift`, using the existing
`Row(label:value:)`, below the version. Absent or empty renders as `—`, which is
what a build made before this change will show.

**Invariants this must not break** (see `app/AGENTS.md`): no change to the split
tunnel, `allowFailover`, ATS or D1; no vendored-tree change. The SHA is not
sensitive — it names a commit in a repository the owner controls — but it is
still device-local, and nothing here sends it anywhere.

## 5. State and migration

Nothing persisted. `LatchkeyGitSHA` is baked into the bundle at build time. An
app built before this change has no such key and shows `—`; no migration.

## 6. End-to-end tests

The dirty-tree guard is a shell check, and the repo already has the right idiom
for those: `scripts/check-fixture-tailnets.sh` **proves itself on a planted
sample before it looks at anything real**, because a guard that cannot
demonstrate itself is only an opinion.

| Test | Suite | Asserts | Shown to fail by |
|---|---|---|---|
| The guard proves itself | `app/scripts/testflight.sh` self-test, run on every invocation | In a throwaway `git init` repo: clean passes; one modified tracked file is refused; one **untracked** `.swift` under `App/` is refused | Removing the untracked case from the guard: the self-test reports that it failed to catch a planted file, and the script aborts before archiving |
| A real dirty tree is refused | manual, recorded in the spec log | `touch` a tracked file, run `make tf`, observe refusal *before* the archive starts | It is the observation |
| The commit reaches the artefact | `make test-policy` host test | A built `Info.plist` carries `LatchkeyGitSHA` matching `git rev-parse --short=12 HEAD` | Dropping the `LATCHKEY_GIT_SHA=` argument: the key is absent and the test says which |
| The row renders | L1 | Settings → Diagnostics shows a non-empty commit row | Building without the setting: the row reads `—` and the assertion names it |

## 7. Acceptance criteria

1. `make tf` on a dirty tree exits non-zero, naming every dirty path, in under
   two seconds and without invoking `xcodebuild`.
2. `make tf UPLOAD=0` still works on a dirty tree, and stamps `-dirty`.
3. A TestFlight build's Diagnostics screen names a commit that exists in the
   repository and whose tree matches what shipped.
4. The self-test catches a planted untracked `.swift` under `App/`.

## 8. Open questions and owner actions

- Should the refusal also require that `HEAD` be *pushed*? It cannot be, here —
  a policy blocks the agent from pushing and Olof pushes by hand — so a build can
  legitimately name a commit that exists nowhere else yet. Left out deliberately;
  worth revisiting once the repository is on GitHub and pushing is routine.
- No owner action.

## 9. Log

Opened 2026-09-24, from two builds made that day out of a dirty tree.
