#!/usr/bin/env python3
"""Delete the UI tests for features Latchkey removed (PLAN §1.10).

Upstream's suite is 29 tests in one 2,275-line file. Fifteen of them exercise
tabs, bookmarks, the address bar, the exit node, the workspace switcher, or
the Aperture chat UI's own input -- none of which exist any more. Rather than
rewrite the file, this removes exactly those test methods and leaves
everything else, including the helper code, intact: the helpers encode a lot
of hard-won waiting and simulator handling that is still worth having.

Brace-matched removal, not regex. Run --check to list what remains.
"""
from __future__ import annotations

import re
import sys

SUITE = "UITests/LatchkeyUITests.swift"

# Each entry: (test name, why it goes)
REMOVED = [
    ("testExitNodeChangesEgressIP",
     "exit node removed (§1.8) -- broken under tsnet, see §7.4"),
    ("testAddAndSwitchWorkspacePersists",
     "no workspace-switcher UI; one gateway, one identity (§1.3)"),
    ("testWorkspaceTabsSurviveSwitching", "tabs removed (§1.4)"),
    ("testTabsPersistAcrossRelaunchAndCapAtTen",
     "tabs removed (§1.4); the cap is now 1"),
    ("testWorkspaceHomePagesAreIsolated", "no workspace switcher to isolate across"),
    ("testOpenNewChatTab", "tabs removed (§1.4)"),
    ("testOpenAndCancelAddBookmark", "bookmarks removed (§1.6)"),
    ("testURLBarSurvivesWebFocusBlurCycle", "address bar removed (§1.5)"),
    ("testConnectionTypeIndicatorNotInternet",
     "the indicator lived in the deleted toolbar (§1.5)"),
    ("testChatInputKeyboardLayoutRepro",
     "asserts against the Aperture chat UI's input; KiroCrew's is a different page"),
    ("testHomePageInputKeyboardNoOverlap", "same"),
    # The four error-overlay tests all drive navigation by typing into the
    # address bar. The overlay itself survives and still matters, so these are
    # a real coverage loss, not dead weight -- recorded in DECISIONS.md and
    # re-established at L1 in M2, where the harness can serve a bad response
    # without needing a URL bar at all.
    ("testBadURLShowsErrorOverlay", "needs the address bar to enter a bad URL (§1.5)"),
    ("testNavErrorOverlayShowsEscapedURLAndCategory", "same"),
    ("testHTTPSCertMismatchShowsError", "same"),
    ("testValidHTTPSURLDoesNotShowInvalidError", "same"),
]


def remove_func(text: str, name: str) -> tuple[str, bool]:
    """Remove `func <name>(...)  { ... }` plus the doc comment above it."""
    match = re.search(r"^([ \t]*)func %s\s*\(" % re.escape(name), text, re.M)
    if not match:
        return text, False
    start = match.start()

    # Walk back over the doc comment / attribute lines directly above.
    line_start = text.rfind("\n", 0, start) + 1
    probe = line_start
    while probe > 0:
        prev_start = text.rfind("\n", 0, probe - 1) + 1
        line = text[prev_start:probe].strip()
        if line.startswith("///") or line.startswith("//") or line.startswith("@"):
            probe = prev_start
            continue
        break
    start = probe

    # Find the opening brace of the body, then its match.
    brace = text.index("{", match.end() - 1)
    depth = 0
    i = brace
    while i < len(text):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                break
        i += 1
    end = i + 1
    # Swallow the trailing newline(s) so no blank run is left behind.
    while end < len(text) and text[end] == "\n":
        end += 1
    return text[:start] + text[end:], True


def check() -> int:
    body = open(SUITE).read()
    names = re.findall(r"^\s*func (test\w+)", body, re.M)
    print(f"{len(names)} test(s) remain in {SUITE}:")
    for n in sorted(names):
        print("  " + n)
    return 0


if __name__ == "__main__":
    if "--check" in sys.argv:
        sys.exit(check())
    body = open(SUITE).read()
    before = len(re.findall(r"^\s*func (test\w+)", body, re.M))
    for name, reason in REMOVED:
        body, ok = remove_func(body, name)
        print(f"  {'removed ' if ok else 'NOT FOUND'} {name}  -- {reason}")
    after = len(re.findall(r"^\s*func (test\w+)", body, re.M))
    print(f"{before} -> {after} tests")
    if body.count("{") != body.count("}"):
        sys.exit(f"refusing to write: unbalanced braces "
                 f"({body.count('{')} open, {body.count('}')} close)")
    open(SUITE, "w").write(body)
    print("ok")
