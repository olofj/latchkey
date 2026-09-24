#!/usr/bin/env python3
"""Add a "Testing" build configuration that defines LATCHKEY_TEST_HOOKS (revision R15).

Test hooks — launch arguments that can point the app at another proxy, a fake
control plane, a staged auth key, or reset its state — must not exist in the
build that goes on the phone. That build is installed with Xcode's Run, which
uses the Debug configuration, so gating on DEBUG gates nothing.

This clones every Debug XCBuildConfiguration (project, app target, UI-test
target) into a "Testing" one and adds LATCHKEY_TEST_HOOKS to the project-level
SWIFT_ACTIVE_COMPILATION_CONDITIONS there; the targets inherit it. The shared
scheme's Test action then builds with Testing. Run and Profile keep Debug and
Release, which do not define the flag.

Idempotent: does nothing if a Testing configuration already exists.
"""
from __future__ import annotations

import hashlib
import re
import sys

PBXPROJ = "Latchkey.xcodeproj/project.pbxproj"
SCHEME = "Latchkey.xcodeproj/xcshareddata/xcschemes/Latchkey.xcscheme"
FLAG = "LATCHKEY_TEST_HOOKS"


def new_id(seed: str) -> str:
    """A deterministic 24-hex-digit object id, so reruns and reviews agree."""
    return hashlib.sha1(("latchkey-testing:" + seed).encode()).hexdigest()[:24].upper()


def main() -> int:
    s = open(PBXPROJ).read()
    if "name = Testing;" in s:
        print("Testing configuration already present; nothing to do")
        return 0

    # Every Debug build configuration object.
    block_re = re.compile(
        r"(\t\t(?P<id>[0-9A-F]{24}) /\* Debug \*/ = \{\n\t\t\tisa = XCBuildConfiguration;\n.*?\n\t\t\tname = Debug;\n\t\t\};\n)",
        re.S)
    blocks = list(block_re.finditer(s))
    if len(blocks) != 3:
        sys.exit(f"expected 3 Debug configurations (project, app, UI tests), found {len(blocks)}")

    clones = []
    id_map = {}
    for m in blocks:
        old_id = m.group("id")
        tid = new_id(old_id)
        id_map[old_id] = tid
        body = m.group(1)
        body = body.replace(f"{old_id} /* Debug */", f"{tid} /* Testing */", 1)
        body = body.replace("\t\t\tname = Debug;", "\t\t\tname = Testing;")
        if 'SWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG $(inherited)";' in body:
            body = body.replace('SWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG $(inherited)";',
                                f'SWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG {FLAG} $(inherited)";')
        clones.append((m.end(), body))

    if not any(FLAG in body for _, body in clones):
        sys.exit("no Debug configuration carried SWIFT_ACTIVE_COMPILATION_CONDITIONS; flag not placed")

    # Insert each clone right after its Debug original, back to front.
    for end, body in sorted(clones, key=lambda c: c[0], reverse=True):
        s = s[:end] + body + s[end:]

    # Register each clone in its configuration list, after the Debug entry.
    for old_id, tid in id_map.items():
        entry = f"\t\t\t\t{old_id} /* Debug */,\n"
        if s.count(entry) != 1:
            sys.exit(f"configuration list entry for {old_id} not found exactly once")
        s = s.replace(entry, entry + f"\t\t\t\t{tid} /* Testing */,\n")

    if s.count("{") != s.count("}"):
        sys.exit("unbalanced braces after edit; refusing to write")
    open(PBXPROJ, "w").write(s)

    sch = open(SCHEME).read()
    new_sch, n = re.subn(r'(<TestAction\n\s*buildConfiguration = )"Debug"', r'\1"Testing"', sch)
    if n != 1:
        sys.exit(f"TestAction buildConfiguration not found exactly once ({n})")
    open(SCHEME, "w").write(new_sch)

    print(f"added Testing configuration ({len(clones)} objects); scheme Test action uses it")
    return 0


if __name__ == "__main__":
    sys.exit(main())
