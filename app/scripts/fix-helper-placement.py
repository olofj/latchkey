#!/usr/bin/env python3
"""Move the re-point helpers into the test class.

repoint-uitests.py appended them before the file's LAST closing brace, which
is the end of a trailing `private extension XCUIElement`, not the end of
`LatchkeyUITests`. They compile there but are invisible to the tests. Move the
block to just before the test class's own closing brace.
"""
from __future__ import annotations

import sys

SUITE = "UITests/LatchkeyUITests.swift"
MARKER = "    // MARK: - Latchkey re-points"
EXTENSION_HEADER = "// MARK: - XCUIElement helpers"

body = open(SUITE).read()

start = body.index(MARKER)
# The block runs to the end of the last helper before the extension's closing
# brace, which is the final "\n}" of the file.
end = body.rstrip().rfind("\n}")
block = body[start:end].rstrip("\n")
body = body[:start].rstrip("\n") + "\n" + body[end:]

# Re-insert before the test class's closing brace, which is the "}" directly
# above the XCUIElement extension's MARK comment.
anchor = body.index(EXTENSION_HEADER)
class_close = body.rfind("\n}\n", 0, anchor)
if class_close == -1:
    sys.exit("could not locate the test class's closing brace")

body = body[:class_close] + "\n\n" + block + "\n" + body[class_close + 1:]

if body.count("{") != body.count("}"):
    sys.exit(f"refusing to write: unbalanced braces "
             f"({body.count('{')} open, {body.count('}')} close)")
open(SUITE, "w").write(body)
print("ok: helpers moved into LatchkeyUITests")
