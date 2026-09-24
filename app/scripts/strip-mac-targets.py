#!/usr/bin/env python3
"""Remove the macOS and virtualization targets from Aperture.xcodeproj.

One-shot surgery for Latchkey milestone M1.1 / M1.2. Kept in the tree because
a `git merge upstream/main` that re-adds Mac objects will need it run again,
and because a hand-edited pbxproj is otherwise unreviewable.

The removal is keyed on upstream's own synthetic object-id prefixes, which
happen to partition the project exactly along the line we want:

    A1xxxx…  ApertureMac target, its build phases/configs, the native macOS
             TailscaleKit.framework, and the "App"/"MacApp" folder exception
             sets that give ApertureMac its membership overrides
    B1xxxx…  ApertureMacUITests target and its dependency proxy
    D1xxxx…  the Packages/ApertureVM local SwiftPM package and its product
             dependency

Everything the iOS app needs uses C20F…/C213…/C22…/C25…/F1… ids, so nothing
shared is touched. Verify with `--check` after running.
"""
from __future__ import annotations

import re
import sys

PBXPROJ = "Aperture.xcodeproj/project.pbxproj"
# 24 hex chars, of which the first two identify the owner.
DEAD_ID = re.compile(r"\b(?:A1|B1|D1)[0-9A-F]{22}\b")


def strip(text: str) -> str:
    lines = text.split("\n")
    out: list[str] = []
    i = 0
    while i < len(lines):
        line = lines[i]
        stripped = line.strip()
        head = stripped.split(" ", 1)[0]
        if DEAD_ID.fullmatch(head):
            if stripped.endswith("{"):
                # Multi-line object: skip to its matching close brace. The
                # opening line contributes depth 1, so track from there.
                depth = 0
                while i < len(lines):
                    depth += lines[i].count("{") - lines[i].count("}")
                    i += 1
                    if depth <= 0:
                        break
                continue
            if stripped.endswith("};"):
                # Single-line object definition.
                i += 1
                continue
        # Any other line mentioning a dead id is a list element or a
        # cross-reference; drop it.
        if DEAD_ID.search(line):
            i += 1
            continue
        out.append(line)
        i += 1
    text = "\n".join(out)

    # Collapse the containers those removals emptied. An empty `exceptions`
    # or `packageReferences` key is legal but noisy; an empty SwiftPM section
    # makes Xcode re-add a resolution step for nothing.
    text = re.sub(r"[ \t]*exceptions = \(\n[ \t]*\);\n", "", text)
    text = re.sub(r"[ \t]*packageReferences = \(\n[ \t]*\);\n", "", text)
    for section in ("XCLocalSwiftPackageReference", "XCSwiftPackageProductDependency"):
        text = re.sub(
            r"/\* Begin %s section \*/\n/\* End %s section \*/\n\n?" % (section, section),
            "",
            text,
        )
    return text


def check(text: str) -> int:
    leftovers = sorted(set(DEAD_ID.findall(text)))
    problems = []
    if leftovers:
        problems.append(f"{len(leftovers)} dangling object id(s): {leftovers[:5]}")
    for needle in ("ApertureMac", "ApertureVM", "MacApp", "MacUITests"):
        if needle in text:
            problems.append(f"still references {needle!r}")
    if text.count("{") != text.count("}"):
        problems.append(f"unbalanced braces: {text.count('{')} open, {text.count('}')} close")
    if problems:
        for p in problems:
            print(f"FAIL: {p}", file=sys.stderr)
        return 1
    print("ok: no macOS/virtualization objects remain, braces balanced")
    return 0


if __name__ == "__main__":
    body = open(PBXPROJ).read()
    if "--check" in sys.argv:
        sys.exit(check(body))
    open(PBXPROJ, "w").write(strip(body))
    sys.exit(check(open(PBXPROJ).read()))
