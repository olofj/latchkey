# F26 — Every TestFlight build says what changed and what to try

| | |
|---|---|
| **Status** | spec |
| **Requested** | 2026-10-09, by Olof: per-build changelog notes on TestFlight uploads, because another tester (Deepak) gets every build "with no idea what changed or why it was sent". Approved shape: a purpose line per build, what changed from the feature specs that landed since the previous build, things to try from each feature's device check, a `tf/<build>` tag per upload, notes set after processing, and a dry run. |
| **Testers** | TestFlight builds now say why they were sent and what to try |
| **Touches** | `app/scripts/testflight.sh`, a new `app/scripts/tf_notes.py`, the Makefile, `docs/TESTFLIGHT.md`. Nothing in the app. |

## 1. Why

`make tf` uploads with `altool`, which cannot set a build's "What to Test"
text. So every build so far reached testers with an empty field: the
TestFlight app and the new-build email say only "Latchkey 0.1 (202610090504)
is available". Olof knows what each build is for. Deepak does not.

The field is the build's `betaBuildLocalizations.whatToTest` in the App Store
Connect API (en-US, at most 4000 characters). The API key `make tf` already
uses for altool (`app/.asc-key`, `~/.appstoreconnect/private_keys/`) can set
it, with an ES256 JWT.

## 2. What the owner sees

Working:

- `make tf PURPOSE="Check the edge swipes again"` archives, exports and
  uploads as before. Before uploading, it prints the notes it will set and
  saves them to `app/build/testflight-notes/<build>.txt` and to
  `app/build/appstore/WhatToTest.txt` beside the `.ipa`.
- After altool succeeds, the commit gets an annotated tag `tf/<build>`. Its
  message is the notes.
- The script then waits for App Store Connect to finish processing the build
  (polling every 30 s, up to 30 min by default) and sets What to Test. The
  last line says it was set.
- In TestFlight, the build reads like this:

  ```
  Why this build: Check the edge swipes again

  What changed since build 202610090504:
  - F25: Mute the dashboard's notification chirps
  - Fixed: dashboard read-aloud plays nothing on iPhone
  - Plus 2 internal changes with nothing new to try.

  Things to try:
  F25: Mute the dashboard's notification chirps
  - On the new build, music plays and a turn finishes: no chirp, no pause.
  - Tap unmute: the next notification chirps.
  - Muted, tap Speak on a reply: it is heard.

  Commit 0123456789ab (Settings → Status shows it).
  ```

- `make tf-notes DRY=1 PURPOSE="..."` prints the notes `make tf` would set
  for HEAD now, and changes nothing anywhere.
- `make tf-notes BUILD=<n>` sets the notes for an uploaded build later, from
  its `tf/<n>` tag. With `DRY=1` it looks the build up read-only, says what
  it would write, and writes nothing.

Failing:

- **No PURPOSE** (or an empty one): `make tf` refuses before it builds
  anything, in the same pre-flight step as the dirty-tree check. The notes
  exist so that testers know why the build came; a build without a reason
  should not reach them. `UPLOAD=0` does not need one (the build reaches
  nobody); its notes say "(no purpose given)".
- **PURPOSE longer than 500 characters**: refused. It is a line, not the
  notes.
- **No baseline** (no `tf/*` tag and no build-history row that is an
  ancestor of HEAD): refused before building, naming `BASELINE=<commit>` as
  the way out.
- **Processing outlasts the wait** (`TF_NOTES_WAIT`, default 1800 s):
  the script stops with exit status 3 and says "the upload succeeded; the
  notes are not set yet; run `make tf-notes BUILD=<n>`". The tag and the
  saved notes are already in place.
- **Processing failed** (`FAILED` or `INVALID`): stops with that state. No
  notes are set.
- **An API error**: the HTTP status and App Store Connect's error detail.
  The upload is not undone.
- **App Store Connect has a newer build than the baseline** (a build that was
  uploaded from somewhere without its tag reaching this clone): a warning,
  naming the build. The notes then repeat what that build already had, which
  is less bad than refusing to send.

## 3. Non-goals

- No localisations other than en-US.
- No release notes for the App Store; this is TestFlight's field only.
- No edits to notes after the fact beyond re-running `make tf-notes`, which
  overwrites the field with the tag's message.
- No external-tester group management, no Beta App Review submission.
- The notes are not written by a model. They are assembled from the specs,
  the commits and the GitHub issues, so the same tree always gives the same
  text.

## 4. Design

### 4.1 The range: the baseline

The notes cover the commits `baseline..HEAD`. The baseline is the newest of:

1. every tag `tf/<build>` whose commit is an ancestor of HEAD (and, when the
   build being made is known, whose build number is lower); and
2. the rows of the **Build history** table in `docs/TESTFLIGHT.md` whose
   commit is an ancestor of HEAD.

Newest means the highest build number (the numbers are UTC timestamps).
`BASELINE=<commit>` overrides both.

The table is how the first build with notes finds where it starts: no build
before this feature was tagged. It is seeded with the last known build, read
from the archive `make tf` left behind: `app/build/Latchkey-appstore.xcarchive`
is build 202610090504, its `LatchkeyGitSHA` is `f72423742cba`, the build F24
§8 was accepted on. Once tags exist the table is only a fallback, so it does
not need a row per build.

**Tags are local until Olof pushes.** Worktrees share the repository's refs,
so every worktree on this Mac sees every tag as soon as it is made. A fresh
clone, or another Mac, does not see an unpushed tag; it falls back to the
table, whose baseline is older, so its notes would repeat earlier changes.
They would never miss a change. Two mitigations:

- the tags are annotated, so `git push --follow-tags` (or `git config
  push.followTags true` once) carries them with the commits;
- the script asks App Store Connect (read-only) for the newest build of the
  app, and warns when it is newer than the baseline and has no tag here.

### 4.2 What changed

Every commit in the range is classified by the files it touches. A commit
**ships** if it touches one of `app/App/`, `app/TSNet/`, `app/ShareExtension/`,
`app/ThirdParty/`, `app/Latchkey/`, `app/Latchkey.xcodeproj/`,
`app/Latchkey.xcconfig`. Docs, tests (`app/UITests/`), scripts and harnesses
reach no tester and are never listed. This is what keeps F25 out today: its
spec landed on main in `df7af62d1`, a docs-only commit, and its code is on
the unmerged `f25` branch.

A shipping commit is attributed, in order:

1. **to a feature** if its body has `Spec: docs/features/F<n>-….md`, or a
   `Fixes #k` / `Closes #k` where the README row of F<n> names `issue #k`;
2. **to a fix** if it has a `Fixes #k` or `Closes #k` that no feature
   claims. The line is `Fixed: <issue title>`, the title from `gh issue view`
   with its `area: ` prefix dropped (issue titles are written for a reader;
   commit subjects are not). Without `gh` or the network, the commit subject
   minus its area is used instead;
3. **otherwise to "internal"**: counted, not listed ("Plus 2 internal changes
   with nothing new to try.").

This is the sane way to include non-feature fixes asked about: the issue
tracker already holds a sentence about each user-visible bug, and AGENTS.md
already asks for `Fixes #k` on the commit that closes one.

A feature's line is `F<n>: <title>`, the title being the spec's `# F<n> —`
heading. A spec whose heading reads badly as a change may add a
`| **Testers** | <one line> |` row to its header table, which is used instead
(TEMPLATE.md gains the row). Features are listed in number order, fixes in
issue order. No shipping commit at all gives `No changes to the app since
build <baseline>.`

### 4.3 Things to try

For each listed feature, the spec's device check: the first heading whose
text contains "device check", or a bullet that starts with `**Device check`,
and the numbered or bulleted list under it. F25 has `## 6. Device check`;
F24 has `- **Device check (owed):**` with a nested list. Each item is
condensed: continuation lines joined, markdown dropped (backticks, bold,
links keep their text), section references such as `(§5)` removed, and
whitespace collapsed. An item that ends in `(owner only)` is left out, for
checks that need Diagnostics or a Mac rather than a tester. A feature without
a device check is listed under What changed and not here. Fixes have no
section of their own.

### 4.4 The 4000-character cap

App Store Connect refuses a longer `whatToTest`. The notes are cut to fit,
in this order, until they do: the last things-to-try items, each replaced by
one line `(N more checks in the specs)`; then whole feature blocks of things
to try; then the last What changed lines, replaced by `- and N more`. The
purpose line and the headings are never cut. Length is counted in UTF-16
code units, which is never less than the character count, so the cap holds
for either reading.

### 4.5 App Store Connect

`app/scripts/tf_notes.py`, standard library only, plus `openssl` for the
signature (neither PyJWT nor `cryptography` is installed here; see
TESTFLIGHT.md). The JWT is ES256: `openssl dgst -sha256 -sign` gives a DER
signature, converted to the raw 64-byte `r||s` JWS wants. Claims: `iss` the
issuer, `aud` `appstoreconnect-v1`, `exp` 15 minutes on; a fresh token per
request, so a 30-minute wait never outlives one.

Calls, against `ASC_API_BASE` (default `https://api.appstoreconnect.apple.com`):

1. `GET /v1/apps?filter[bundleId]=<id>`: the app. The bundle id is
   `LATCHKEY_BUNDLE_ID` from `Local.xcconfig`, else `Latchkey.xcconfig`.
2. `GET /v1/builds?filter[app]=<app>&filter[version]=<build>`: the build and
   its `processingState`. Absent is normal for a few minutes after altool
   returns; it is polled like `PROCESSING`.
3. `GET /v1/builds/<id>/betaBuildLocalizations`: the existing localisations.
4. `PATCH /v1/betaBuildLocalizations/<id>` with `whatToTest` if en-US
   exists; otherwise `POST /v1/betaBuildLocalizations` with `locale: en-US`
   and the build relationship.

Read-only for the baseline warning: `GET /v1/builds?filter[app]=<app>&sort=-version&limit=1`.

Commands:

- `tf_notes.py notes [--purpose P] [--build N] [--out FILE]...` prints the notes.
- `tf_notes.py set --build N (--notes-file F | --from-tag) [--wait S] [--dry-run]`.
- `tf_notes.py latest` prints the newest build App Store Connect has (read-only).

### 4.6 `testflight.sh` and the Makefile

- Pre-flight (`TF_CHECK_ONLY=1`, before the framework build): after the
  dirty-tree check, refuse a missing PURPOSE when uploading, and generate the
  notes once to `/dev/null` so a missing baseline fails in seconds.
- After the export: generate the notes, print them, save them to both
  places. `UPLOAD=0` stops here, which makes it a full dry run of the notes
  too.
- After altool: `git tag -a --cleanup=verbatim -F <notes> tf/<build> <sha>`,
  then `tf_notes.py set --build <build> --from-tag --wait $TF_NOTES_WAIT`.
  `TF_NOTES=0` skips the wait and the setting, for an upload from a machine
  that cannot wait; `make tf-notes BUILD=<n>` finishes it.
- `make tf-notes` passes `BUILD`, `DRY`, `PURPOSE` and `BASELINE` through
  the environment; make exports command-line variables to its recipes, so a
  purpose with an apostrophe needs no extra quoting.

**Invariants this must not break** (see `../../app/AGENTS.md`): none of the
app's are touched; nothing changes in the binary. F12's guards stay as they
are: the tag names the same commit the build is stamped with, and is made
only after the clean-tree and HEAD-did-not-move checks have passed and the
upload succeeded.

## 5. State and migration

- `tf/<build>` annotated tags, local until pushed (§4.1).
- `docs/TESTFLIGHT.md` § Build history: one seed row, read by the script.
- `app/build/testflight-notes/<build>.txt` (gitignored, kept across builds)
  and `app/build/appstore/WhatToTest.txt` (replaced by the next export).
- App Store Connect: the build's en-US `whatToTest`. Builds uploaded before
  this keep their empty field.

## 6. Tests

Host-level, `app/scripts/test-tf-notes.py` run by
`app/scripts/test-tf-notes.sh` in `make test-policy`. Each test builds a
throwaway git repository with specs, a README and commits, and runs the real
generator against it. The App Store Connect calls run against a fake HTTP
server in the same process; nothing reaches Apple. No simulator.

| Test | Asserts | Shown to fail by |
|---|---|---|
| baseline from tag | the newest ancestor `tf/*` tag wins over an older table row; a tag on a side branch is ignored | taking the newest tag regardless of ancestry |
| baseline from table | with no tags, the table row is used; with neither, a clear refusal | removing the table fallback |
| feature detection | a shipping commit with `Spec:` lists the feature; a docs-only commit adding a spec does not (F25's case); `Fixes #k` maps through the README row; an unclaimed `Fixes #k` is a fix with the issue title; a test-only commit is not counted | treating every `Spec:` commit as shipping |
| section extraction | F25-style heading and F24-style bold bullet both yield their items, condensed; `(owner only)` items are dropped; the next heading ends the section | ending the section at the first blank line |
| 4000-char cap | 40 features with long checks give ≤ 4000 UTF-16 units, purpose and headings intact, "more checks" lines present | raising the cap to 40000 inside the generator |
| missing PURPOSE | `notes --require-purpose` with an empty or absent purpose exits non-zero with the message; a 501-character purpose too | dropping the check |
| JWT | the token verifies with the key's public half (`openssl dgst -verify`) after raw-to-DER conversion; header and claims as §4.5 | skipping the DER-to-raw conversion |
| set: patch / post | an existing en-US localisation is PATCHed; none means a POST with the build relationship; the body carries the notes | swapping the branches |
| set: waits, then times out | `PROCESSING` for longer than `--wait` exits 3 with the `make tf-notes BUILD=` message and writes nothing | treating `PROCESSING` as ready |
| set: failed build | `FAILED` exits 1, writes nothing | ignoring the state |

The live service is exercised read-only only: the app lookup, the build
list and an existing build's localisations, to check the key and the queries
(§9).

## 7. Acceptance criteria

- `make test-policy` runs the tests above, and each was seen failing by the
  change in its row.
- `make tf-notes DRY=1 PURPOSE=x` on main prints notes with a baseline of
  202610090504 and changes nothing (no tag, no API write).
- `make tf-notes BUILD=202610090504 DRY=1` reaches App Store Connect,
  finds the build and reports its processing state and current What to Test,
  and writes nothing.
- `make tf` without PURPOSE refuses in under a few seconds, before the
  framework step.

## 8. Open questions and owner actions

- **Push the tags**: `git push --follow-tags`, or `git config
  push.followTags true` once.
- The first real `make tf` with notes is the first write to App Store
  Connect; it has been tested only against the fake. If it fails, the build
  is uploaded and tagged and `make tf-notes BUILD=<n>` retries.
- Whether the "Things to try" of a long device check (F24 has 11 items)
  should be trimmed per feature is a judgement for the first few builds; the
  `(owner only)` marker is the tool.

## 9. Log

(filled in while building)
