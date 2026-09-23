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
     the default tailnet hostnames (`latchkey-iphone` / `-ipad`) -> PRESERVED.
     A workspace already on disk carries its hostname in `workspaces.json`
     anyway, so changing the default would only affect a future fresh install
     while risking a mismatch with Olof's ACL grants.
  4. The vendored libtailscale tree (`ThirdParty/`), including
     `latchkey_locallog.go` and `TestLatchkeyRawStderr...` -> PRESERVED,
     because R16 keeps every vendored change as its own commit and a rename
     there buys nothing but a `make framework` rebuild and a merge hazard.
     `scripts/test-all.sh` therefore keeps `go test -run Latchkey`.

Mechanism: each preserved string is swapped for a sentinel, the renames run,
then the sentinels are restored. That way a bare `Latchkey` can be renamed
wholesale without a hand-maintained list of every safe occurrence, while the
handful of identity strings are protected by name and are visible here.

Run with --check afterwards: every remaining mention must be category 2, 3 or
4, or this file's own text.
"""
from __future__ import annotations

import os
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
    "latchkey",
    # -- category 4: the vendored tree, and the Go test name a script runs
    "latchkey_locallog",
    "latchkey_rawecho",
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


def check() -> int:
    """List what still says Roam. Each hit must be category 2, 3 or 4."""
    out = subprocess.run(["git", "grep", "-nI", "-e", "Latchkey", "-e", "Latchkey",
                          "-e", "latchkey", "-e", "latchkey", "-e", "Latchkey"],
                         capture_output=True, text=True).stdout.splitlines()
    out = [h for h in out if not h.startswith("ThirdParty/")
           and "rename-to-kiro" not in h]
    print(f"{len(out)} remaining mention(s) — each must be bundle identity, a "
          f"storage/hostname literal, or the vendored tree:")
    for h in out:
        print("  " + h)
    return 0


if __name__ == "__main__":
    if "--check" in sys.argv:
        sys.exit(check())
    roots = [a for a in sys.argv[1:] if not a.startswith("-")] or ["."]
    rewrite(roots)
    print("done — review `git diff`, then run with --check in each repo")
