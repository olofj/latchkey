#!/usr/bin/env python3
"""Rename the product from Latchkey to Latchkey (2026-09-23, Olof's call).

Companion to `rename-to-latchkey.py`, which renamed Aperture -> Latchkey.
Read that one first: it explains the shape. This one is harder in exactly one
way, and the difference is the whole reason this file exists.

    THE BUNDLE ID DOES NOT CHANGE.

Olof's instruction was to keep `net.lixom.latchkey` so the app keeps its
existing container and its existing Tailscale node. The previous rename could
move the on-disk data root because -- in its own words --

    "Safe to move: the bundle id changed too, so this is inside a different
     app container and there is nothing to migrate."

That condition is absent now. Same bundle id means the SAME container, so
`<Application Support>/Latchkey/` is a live directory holding this device's
tsnet state dir (the node's identity), `workspaces.json` and the logs.
Renaming that literal would point a renamed app at an empty directory: a new
node key, a fresh login, tailnet-lock re-signing and new grants -- precisely
the "new tailscale setup" the instruction exists to avoid. So the storage
literals stay, and this file is the record of why they look stale.

Four categories, and only the first changes:

  1. The product name -- target, scheme, types, files, display name, prose.
  2. Bundle identity: `net.lixom.latchkey`, the os_log subsystem that mirrors
     it, the DispatchQueue labels, the future App Group -> PRESERVED.
  3. Storage and network identity: the Application Support directory names and
     the default tailnet hostnames -> PRESERVED **by this script**.

     NOTE (later the same day): the hostname default was subsequently changed
     to `latchkey-*` by hand, after checking that the tailnet grant is scoped
     by address range and not by node name. It is only a default -- a live
     install carries its own hostname in `workspaces.json` -- so no existing
     node was renamed. The Application Support names remain frozen, and that
     distinction is the point: storage identity must not move, a default may.
     See `App/Workspace/WorkspaceStore.swift` and the DECISIONS entries.
  4. The vendored libtailscale tree (`ThirdParty/`): its files
     (`latchkey_locallog.go`, `latchkey_nologs.go`, `latchkey_locallog_test.go`,
     `logtail/latchkey_rawecho_test.go`), its Go identifiers (`latchkeyLocalLog`)
     and its test names (`TestLatchkeyRawStderr...`) keep the old name, because
     R16 keeps every vendored change as its own commit and a rename there buys
     nothing but a `make framework` rebuild and a merge hazard.
     `scripts/test-all.sh` therefore keeps `go test -run Latchkey`.

     CORRECTION (the evening of the same day): the tree itself was never
     touched -- `ThirdParty` is in SKIP_DIRS -- but the claim that these names
     were preserved was only true for the two that were in PRESERVE
     (`latchkey_locallog`, `latchkey_rawecho`). PRESERVE did not cover
     `latchkey_nologs` or the camel-case `latchkeyLocalLog`, so every PROSE
     mention of those outside the tree was rewritten: `docs/DECISIONS.md` now
     names a `latchkey_nologs.go` that does not exist, a `latchkey_*.go`
     glob that matches nothing, and a Go test that "drives latchkeyLocalLog".
     `docs/PLAN.md`'s log predicate became `subsystem CONTAINS "latchkey"`,
     which no process logs under (the subsystem is category 2 and stayed
     `net.lixom.latchkey`). The missing names are in PRESERVE now, and
     --check looks in both directions (below), so a re-run holds them and the
     damage is listed rather than assumed away. The lines themselves were
     corrected in their own files' commit (`0beac80`); `--check --rev cbfdc31`
     shows the check catching them in the rename commit that made them.

Mechanism: each preserved string is swapped for a sentinel, the renames run,
then the sentinels are restored. That way a bare `Latchkey` can be renamed
wholesale without a hand-maintained list of every safe occurrence, while the
handful of identity strings are protected by name and are visible here.

The rewrite ran on 2026-09-23 when `app/` was still its own repository, once
from each root; SKIP_DIRS still says so. It is kept as the record and is not
something to run again.

--check is BIDIRECTIONAL, from the repository root:

  1. Leftovers: every remaining mention of the old name. Each must be
     category 2, 3 or 4, or this file's own text. Informational.
  2. New-name strings that must not exist: a preserved identity under its
     new spelling -- `net.lixom.latchkey`, a `Latchkey` Application Support
     path, `latchkey_*.go`, `latchkeyLocalLog`, `-run Latchkey`, a
     `latchkey` os_log subsystem. The list is DERIVED from PRESERVE by
     running each entry through REPLACEMENTS, so the two cannot drift; the
     only hand-written parts are the CONTEXT_RULES (a spelling that cannot be
     derived from one literal, such as a glob or a predicate), each keyed to
     the PRESERVE entry it guards, and HAND_MOVED (a preserved literal whose
     new spelling is legitimate in some places because it was moved by hand
     later). A hit here is damage and the exit status is 1.

A check that greps only for leftovers is blind by construction to names the
script wrongly changed; that is how the corrected lines above went unnoticed
for a day.
"""
from __future__ import annotations

import os
import re
import subprocess
import sys

# Identity strings that must survive verbatim (categories 2-4 above).
# Order matters only in that longer strings must precede shorter ones they
# contain, so the sentinel swap does not split them.
PRESERVE = [
    # -- category 2: bundle identity ------------------------------------
    "net.lixom.latchkey",
    # -- category 3: on-disk data root (same container as before!) ------
    "Latchkey-UI-Test",
    "<Application Support>/Latchkey/",
    "Application Support>/Latchkey",
    # -- category 3: tailnet hostnames, and the repo/directory name -----
    # Bare `latchkey` covers latchkey-iphone, latchkey-ipad, the repo
    # directory ~/src/latchkey and the GitHub repo names.
    # (The hostname default and the GitHub name moved by hand later; see
    # HAND_MOVED. The directory did not.)
    "latchkey",
    # -- category 4: the vendored tree, and the Go test name a script runs
    "latchkey_locallog",
    "latchkey_nologs",     # missing on the first run: see the CORRECTION above
    "latchkey_rawecho",
    "latchkeyLocalLog",    # missing on the first run: see the CORRECTION above
    "TestLatchkey",        # TestLatchkeyRawStderr...; `-run Latchkey` below
    "-run Latchkey",
]

# Preserved in Swift sources only. `"Latchkey"` is the Application Support
# directory name (category 3) when it appears in a Swift string literal -- but
# in `project.pbxproj` and `.xcscheme` the very same quoted token is the TARGET
# name, which must be renamed. Protecting it globally silently left the project
# file half-renamed on the first run of this script; hence the split.
PRESERVE_SWIFT = [
    '"Latchkey-UI-Test-iOS"',
    '"Latchkey-UI-Test-macOS"',
    '"Latchkey-UI-Test"',
    '"Latchkey"',
]

# (old, new) applied in order, longest-first, after PRESERVE is masked.
REPLACEMENTS = [
    # Swift types
    ("LatchkeyUITests", "LatchkeyUITests"),
    ("LatchkeyBrandHeader", "LatchkeyBrandHeader"),
    ("LatchkeyApp", "LatchkeyApp"),
    ("LatchkeyLog", "LatchkeyLog"),
    # Build products, project and scheme paths
    ("Latchkey.xcodeproj", "Latchkey.xcodeproj"),
    ("Latchkey.xcscheme", "Latchkey.xcscheme"),
    ("Latchkey.xcarchive", "Latchkey.xcarchive"),
    ("Latchkey.app", "Latchkey.app"),
    ("Latchkey.ipa", "Latchkey.ipa"),
    ("Latchkey/Info.plist", "Latchkey/Info.plist"),
    # The app's own HTTP probe headers. Both ends are ours: the page script in
    # App/Browser/PageScriptSources.swift and the counter in
    # testing/harness/fake_gateway.py. Renamed in lockstep or the session
    # suite's availability check stops being counted.
    ("X-Latchkey-Check", "X-Latchkey-Check"),
    ("X-Latchkey-Share", "X-Latchkey-Share"),
    # Identifiers that exist only in specs not yet built (F6), so free to move.
    ("latchkey.single-origin", "latchkey.single-origin"),
    ("data-latchkey-blocked", "data-latchkey-blocked"),
    # Anything else: the bare product name, in either spelling.
    ("Latchkey", "Latchkey"),
    ("Latchkey", "Latchkey"),
    ("Latchkey", "Latchkey"),
    ("latchkey", "latchkey"),
]

# A preserved literal whose NEW spelling is nevertheless legitimate in some
# places, because part of what it covered was moved by hand after the rewrite.
# Such an entry is not checked as an exact new-name string; only its
# CONTEXT_RULES are. The value says why, and is printed with the check.
# (`latchkey` has no lower-case rule in REPLACEMENTS at all -- the script
# never renamed it, PRESERVE was belt and braces -- so `latchkey` is not
# derivable from it either way; the directory rule below is the whole check.)
HAND_MOVED = {
    "latchkey": "the hostname default (latchkey-iphone/-ipad) and the GitHub "
                 "repo (olofj/latchkey) moved by hand later the same day; only "
                 "the repository directory keeps the old name",
}

# New-name spellings that cannot be derived from one preserved literal -- a
# glob, a predicate, a path spelled without the angle brackets. Each rule is
# keyed to the PRESERVE entry it guards, and check() refuses a key that is not
# in PRESERVE, so a rule cannot outlive or precede the identity it is for.
CONTEXT_RULES = {
    "net.lixom.latchkey": [
        (r'subsystem\b[^\n]{0,40}?["\'][^"\'\n]*latchkey',
         "an os_log predicate naming the subsystem under the new name; the "
         "subsystem is net.lixom.latchkey and such a predicate matches nothing"),
    ],
    "<Application Support>/Latchkey/": [
        (r'Application Support[^\n]{0,16}?Latchkey',
         "the live data root spelled without the angle brackets"),
    ],
    "latchkey_locallog": [
        (r'latchkey_[A-Za-z0-9_*]*\.go',
         "a vendored file name, or a glob over them, under the new name; the "
         "tree's files are latchkey_*.go"),
    ],
    "latchkey": [
        (r'src/latchkey\b',
         "the repository directory is ~/src/latchkey"),
    ],
}

SKIP_DIRS = {".git", "build", "ThirdParty", "app", "logs", "__pycache__",
             "f5-measurement", "Assets.xcassets"}
SKIP_FILES = {
    "rename-to-latchkey.py",   # the previous rename: a record, must not move
    "rename-to-latchkey.py",  # this file
    "strip-mac-targets.py",    # historical records of what they removed
    "strip-mac-makefile.py",
}
EXTENSIONS = {".swift", ".plist", ".xcscheme", ".pbxproj", ".sh", ".py", ".md",
              ".yml", ".yaml", ".json", ".storyboard", ".go", ".js", ".html",
              ".css", ".txt", ".entitlements", ".xcconfig", ""}
NAMED = {"Makefile", "NOTICE"}


def target_files(root: str) -> list[str]:
    found = []
    for dirpath, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS and not d.startswith(".")]
        for name in files:
            if name in SKIP_FILES:
                continue
            if name not in NAMED and os.path.splitext(name)[1] not in EXTENSIONS:
                continue
            found.append(os.path.join(dirpath, name))
    return sorted(found)


def rewrite_body(body: str, path: str = "") -> str:
    """Mask the identity strings, rename, then restore."""
    keeps = list(PRESERVE)
    if path.endswith(".swift"):
        keeps = PRESERVE_SWIFT + keeps
    for i, keep in enumerate(keeps):
        body = body.replace(keep, f"\x00PRESERVE{i}\x00")
    for old, new in REPLACEMENTS:
        body = body.replace(old, new)
    for i, keep in enumerate(keeps):
        body = body.replace(f"\x00PRESERVE{i}\x00", keep)
    return body


def rewrite(roots: list[str]) -> None:
    changed = 0
    for root in roots:
        for path in target_files(root):
            try:
                with open(path) as fh:
                    original = fh.read()
            except (UnicodeDecodeError, IsADirectoryError, FileNotFoundError):
                continue
            body = rewrite_body(original, path)
            if body != original:
                with open(path, "w") as fh:
                    fh.write(body)
                changed += 1
                print(f"  rewrote {path}")
    print(f"{changed} file(s) rewritten")


def move(src: str, dst: str) -> None:
    if not os.path.exists(src):
        print(f"  skip move (missing): {src}")
        return
    if os.path.exists(dst):
        print(f"  skip move (exists):  {dst}")
        return
    subprocess.run(["git", "mv", src, dst], check=True)
    print(f"  moved {src} -> {dst}")


# ------------------------------------------------------------------ check --

def renamed(literal: str) -> str:
    """What REPLACEMENTS would make of a string that was NOT masked: the new
    spelling of a preserved identity, i.e. the string that must not exist."""
    for old, new in REPLACEMENTS:
        literal = literal.replace(old, new)
    return literal


def forbidden_spellings() -> list[tuple[str, str, bool]]:
    """(preserved, its new spelling, swift_only), derived from PRESERVE and
    PRESERVE_SWIFT. Entries the rename would leave unchanged, and HAND_MOVED
    entries (checked by context only), are left out."""
    out = []
    for keep in PRESERVE:
        if keep in HAND_MOVED:
            continue
        new = renamed(keep)
        if new != keep:
            out.append((keep, new, False))
    for keep in PRESERVE_SWIFT:
        new = renamed(keep)
        if new != keep:
            out.append((keep, new, True))
    return out


def git_grep(top: str, patterns: list[str], rev: str | None = None) -> list[str]:
    """`path:line:text` hits in the working tree, or in the tree at `rev`."""
    args = ["git", "grep", "-nI"]
    for p in patterns:
        args += ["-e", p]
    if rev:
        args.append(rev)
    out = subprocess.run(args, capture_output=True, text=True, cwd=top).stdout.splitlines()
    if rev:
        out = [h[len(rev) + 1:] if h.startswith(rev + ":") else h for h in out]
    # The vendored tree keeps the old names on purpose (category 4), and the
    # two rename scripts describe both spellings.
    return [h for h in out if not h.startswith("app/ThirdParty/")
            and not h.startswith("ThirdParty/") and "rename-to-kiro" not in h]


def check(rev: str | None = None) -> int:
    """Both directions: what still says Roam (each hit must be category 2, 3
    or 4), and what says Nomad where a preserved identity belongs (each hit
    is damage). Exit 1 on any of the latter. `rev` checks a committed tree
    instead of the working tree -- how the check is shown able to fail:
    `--check --rev cbfdc31` is the docs rename commit, with the damage in it."""
    top = subprocess.run(["git", "rev-parse", "--show-toplevel"],
                         capture_output=True, text=True, check=True).stdout.strip()
    print(f"checking {'the tree at ' + rev if rev else 'the working tree'} under {top}")

    unknown = set(CONTEXT_RULES) - set(PRESERVE)
    if unknown:
        print(f"CONTEXT_RULES keyed to strings that are not in PRESERVE: {sorted(unknown)}")
        return 2
    unknown = set(HAND_MOVED) - set(PRESERVE)
    if unknown:
        print(f"HAND_MOVED names strings that are not in PRESERVE: {sorted(unknown)}")
        return 2

    # 1. Leftovers of the old name.
    olds = sorted({old for old, _ in REPLACEMENTS} | {"Latchkey", "Latchkey", "latchkey",
                                                    "latchkey", "Latchkey"})
    leftovers = git_grep(top, olds, rev)
    print(f"{len(leftovers)} remaining mention(s) of the old name — each must be bundle "
          f"identity, a storage/hostname literal, or the vendored tree:")
    for h in leftovers:
        print("  " + h)

    # 2. The new name where a preserved identity belongs.
    spellings = forbidden_spellings()
    news = sorted({new for _, new in REPLACEMENTS})
    candidates = git_grep(top, news, rev)
    violations: dict[str, list[str]] = {}   # "path:line:text" -> reasons

    def flag(hit: str, reason: str) -> None:
        violations.setdefault(hit, []).append(reason)

    for keep, new, swift_only in spellings:
        for h in candidates:
            path = h.split(":", 1)[0]
            if swift_only and not path.endswith(".swift"):
                continue
            if new in h.split(":", 2)[2]:
                flag(h, f"`{new}` is preserved `{keep}` under its new spelling")
    for keep, rules in CONTEXT_RULES.items():
        for pattern, why in rules:
            rx = re.compile(pattern)
            for h in candidates:
                if rx.search(h.split(":", 2)[2]):
                    flag(h, f"{why} (guards `{keep}`)")

    print()
    print(f"checked {len(spellings)} derived new-name spelling(s): "
          + ", ".join(f"`{new}`" + (" (Swift only)" if swift_only else "")
                      for _, new, swift_only in spellings))
    print(f"and {sum(len(r) for r in CONTEXT_RULES.values())} context rule(s); "
          f"checked by context only, the bare new name being legitimate elsewhere: "
          + ", ".join(f"`{k}` ({why})" for k, why in HAND_MOVED.items()))
    print()
    if not violations:
        print("0 new-name string(s) where a preserved identity belongs")
        return 0
    print(f"{len(violations)} new-name string(s) where a preserved identity belongs — "
          f"each of these is damage from the rename and must be corrected in its own file:")
    for h in sorted(violations, key=lambda s: (s.split(":", 1)[0], int(s.split(":", 2)[1]))):
        print("  " + h)
        for reason in violations[h]:
            print("      ^ " + reason)
    return 1


if __name__ == "__main__":
    if "--check" in sys.argv:
        rev = None
        if "--rev" in sys.argv:
            rev = sys.argv[sys.argv.index("--rev") + 1]
        sys.exit(check(rev))
    roots = [a for a in sys.argv[1:] if not a.startswith("-")] or ["."]
    rewrite(roots)
    print("done — review `git diff`, then run with --check from the repository root")
