#!/usr/bin/env python3
"""Rename the `openNewTab` callback to `openExternally`.

With tabs removed (PLAN §1.4) the callback hands the URL to the system
browser. A parameter still named `openNewTab` that opens Safari is exactly the
kind of thing that causes the next bug.

(Written as a script because BSD sed has no `\\b`, so the obvious one-liner
silently matches nothing and reports success.)
"""
from __future__ import annotations

import re

FILES = [
    "App/Browser/BrowserViewModel.swift",
    "App/Browser/BrowserTab.swift",
    "App/Browser/TabManager.swift",
]

PATTERN = re.compile(r"\bopenNewTab\b")

for path in FILES:
    body = open(path).read()
    body, n = PATTERN.subn("openExternally", body)
    open(path, "w").write(body)
    print(f"  {path}: {n} occurrence(s)")
