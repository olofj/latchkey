#!/usr/bin/env python3
"""Rename the Aperture product to Latchkey (PLAN §1.11).

One-shot, kept in the tree alongside the other M1 surgery scripts so a future
merge from upstream has a recipe rather than a mystery.

Deliberately NOT a blanket s/Aperture/Latchkey/. Three kinds of "Aperture"
appear in this repo and only one of them should change:

  1. The product        -> renamed (target, scheme, types, log subsystem, ...)
  2. The upstream project it forks, named in provenance prose and in the
     `aperture-plus` repo URL                          -> left alone
  3. Historical prose in timing/ and the README files, which describes
     measurements taken against the Aperture app       -> left alone

So the replacements are an explicit, ordered list of exact strings. Anything
not on the list survives. Longest patterns come first so that, for example,
`ApertureUITests` is not partially rewritten by the bare `Aperture` rule.

Run --check afterwards to see what still says Aperture and confirm each
remaining hit is case 2 or 3.
"""
from __future__ import annotations

import os
import subprocess
import sys

# (old, new) applied in order, longest-first.
REPLACEMENTS = [
    # Swift types and their doc mentions
    ("ApertureUITests", "LatchkeyUITests"),
    ("ApertureBrandHeader", "LatchkeyBrandHeader"),
    ("ApertureApp", "LatchkeyApp"),
    ("ApertureLog", "LatchkeyLog"),
    # Unified logging + bundle identity
    ("io.tailscale.Aperture", "net.lixom.latchkey"),
    # Build products and project/scheme names
    ("Aperture.xcodeproj", "Latchkey.xcodeproj"),
    ("Aperture.xcscheme", "Latchkey.xcscheme"),
    ("Aperture.xcarchive", "Latchkey.xcarchive"),
    ("Aperture.app", "Latchkey.app"),
    ("Aperture.ipa", "Latchkey.ipa"),
    ("Aperture/Info.plist", "Latchkey/Info.plist"),
    # On-disk data root. Safe to move: the bundle id changed too, so this is
    # inside a different app container and there is nothing to migrate.
    ("<Application Support>/Aperture/", "<Application Support>/Latchkey/"),
    ('"Aperture-UI-Test-iOS"', '"Latchkey-UI-Test-iOS"'),
    ('"Aperture-UI-Test-macOS"', '"Latchkey-UI-Test-macOS"'),
    ('"Aperture-UI-Test"', '"Latchkey-UI-Test"'),
    ('Root for all Aperture data', 'Root for all Latchkey data'),
    # User-visible strings
    ('displayName: "Aperture"', 'displayName: "Latchkey"'),
    ('displayTitle = "Aperture"', 'displayTitle = "Latchkey"'),
    ('where it is rather than "Aperture".', 'where it is rather than "Latchkey".'),
    ("fatal error: Aperture detected", "fatal error: Latchkey detected"),
    ("all Aperture/libtailscale messages", "all Latchkey/libtailscale messages"),
    # Stale prose: these described looking for an Aperture chat instance; the
    # app now looks for a KiroCrew gateway.
    ("turn a missing Aperture instance into a", "turn a missing KiroCrew gateway into a"),
    ("the configured Aperture instance is missing", "the configured gateway is missing"),
    # File headers: `//  Aperture` on its own line.
    ("\n//  Aperture\n", "\n//  Latchkey\n"),
    ("\n//  Aperture+\n", "\n//  Latchkey\n"),
]

# Files where every occurrence is a product reference, with no upstream
# provenance prose to protect, so a wholesale replacement is correct and
# catches target names, group comments and build settings in one go.
WHOLESALE_SUFFIXES = (".pbxproj", ".xcscheme")

# Files to rewrite. Asset catalogue names (ApertureIcon, ApertureWordmark) are
# left alone: they are image assets, and renaming them means renaming
# directories inside Assets.xcassets for a cosmetic gain. M8.1 replaces the
# artwork anyway.
SKIP_DIRS = {".git", "build", "ThirdParty", "Assets.xcassets", "timing"}
SKIP_FILES = {
    "NOTICE",                                # provenance: must keep saying Aperture
    "AGENTS.md",                             # upstream's own notes
    "README.md",
    "README.ui-automation.md",
    "README.tsnet-exit-nodes-dont-work.md",
    "TODO.failing-tests.md",
    "rename-to-latchkey.py",                 # this file
    "strip-mac-targets.py",                  # historical record of what it removed
    "strip-mac-makefile.py",
}
EXTENSIONS = {".swift", ".plist", ".xcscheme", ".pbxproj", ".sh", ".py", ".storyboard", ""}


def target_files() -> list[str]:
    found = []
    for root, dirs, files in os.walk("."):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS and not d.startswith(".")]
        for name in files:
            if name in SKIP_FILES:
                continue
            ext = os.path.splitext(name)[1]
            if ext not in EXTENSIONS and name != "Makefile":
                continue
            found.append(os.path.join(root, name))
    return sorted(found)


def rewrite() -> None:
    changed = 0
    for path in target_files():
        try:
            body = open(path).read()
        except (UnicodeDecodeError, IsADirectoryError):
            continue
        original = body
        if path.endswith(WHOLESALE_SUFFIXES):
            body = body.replace("Aperture", "Latchkey")
        else:
            for old, new in REPLACEMENTS:
                body = body.replace(old, new)
        if body != original:
            open(path, "w").write(body)
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
    hits = subprocess.run(
        ["git", "grep", "-n", "Aperture"], capture_output=True, text=True
    ).stdout.splitlines()
    hits = [h for h in hits if not h.startswith("ThirdParty/")]
    print(f"{len(hits)} remaining mention(s) of 'Aperture' — each should be "
          f"upstream provenance or historical prose:")
    for h in hits:
        print("  " + h)
    return 0


if __name__ == "__main__":
    if "--check" in sys.argv:
        sys.exit(check())
    # Content first, then the paths those contents now reference.
    rewrite()
    move("Aperture", "Latchkey")
    move("Aperture.xcodeproj/xcshareddata/xcschemes/Aperture.xcscheme",
         "Aperture.xcodeproj/xcshareddata/xcschemes/Latchkey.xcscheme")
    # The project bundle goes last: it touches the most paths.
    move("Aperture.xcodeproj", "Latchkey.xcodeproj")
    print("done — now run: python3 scripts/rename-to-latchkey.py --check")
