#!/usr/bin/env python3
"""Re-point the surviving UI tests at the UI that still exists (PLAN §1.10).

prune-uitests.py removed the tests for deleted features. This fixes the
survivors, which still reach for accessibility identifiers that went away with
the browser toolbar and the tab overview.

Also removes one more test, `testLogoutDeletesWorkspaceAndReplacesLastSession`:
it adds a second workspace through the tab overview's session menu, which no
longer exists. Multiple side-by-side workspaces are a §1.3 non-goal (PLAN §9
keeps the door open). Logout itself stays covered — the Settings logout button
is unchanged and `testOpenAndCloseSettings` still reaches it.
"""
from __future__ import annotations

import re
import sys

SUITE = "UITests/LatchkeyUITests.swift"

REMOVE_FUNCS = [
    "testLogoutDeletesWorkspaceAndReplacesLastSession",
    "openSessionMenu",    # tab-overview session menu: gone
    "workspaceRows",      # only that test used it
]

REPLACEMENTS = [
    # The brand header was renamed with the product.
    ('''    /// Waits for the brand header (the "Aperture" logo lockup) to appear. It's
    /// the sole "Aperture" branding (no nav-bar title), present in both the
    /// connection gate and (post-connection) the browser chrome. Matches any
    /// element type via `descendants(matching: .any)` for robustness.''',
     '''    /// Waits for the brand header to appear. It is the app's only branding
    /// (there is no nav-bar title) and lives in the connection gate. Matches
    /// any element type via `descendants(matching: .any)` for robustness.'''),
    ('.matching(identifier: "aperture-brand-header").firstMatch',
     '.matching(identifier: "latchkey-brand-header").firstMatch'),

    # "Browser chrome is up" used to mean the toolbar's more-menu button. With
    # no toolbar, the connected-browser marker carries that signal.
    ('''        XCTAssertTrue(app.buttons["more-menu-button"].waitForExistence(timeout: 15),
                      "Browser chrome should appear after a successful relogin")''',
     '''        XCTAssertTrue(connectedBrowserMarker(app).waitForExistence(timeout: 15),
                      "The dashboard should appear after a successful relogin")'''),

    # Reload was a toolbar button; it is now Cmd-R (DashboardRootView's hidden
    # command). `typeKey` reaches it on the simulator with the hardware
    # keyboard connected, which run-uitests.sh already ensures.
    ('''        let reload = app.buttons["reload-button"]
        XCTAssertTrue(reload.waitForExistence(timeout: 10))
        reload.tap()''',
     '''        reloadPage(app)'''),
]

# Appended just before the final closing brace of the test class.
NEW_HELPERS = '''
    // MARK: - Latchkey re-points

    /// The marker `DashboardRootView` draws once the dashboard is presented.
    /// Replaces the old "does the toolbar exist yet" check, since there is no
    /// toolbar any more.
    func connectedBrowserMarker(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: "connected-browser").firstMatch
    }

    /// Reloads the page. The reload button lived in the browser toolbar that
    /// PLAN §1.5 deleted, so this drives the Cmd-R command `DashboardRootView`
    /// keeps in its hidden command group instead.
    ///
    /// Needs a connected hardware keyboard in the simulator
    /// (`run-uitests.sh` enables it). If this ever proves flaky, the fallback
    /// is a debug-only reload affordance behind a launch argument — but do not
    /// add one speculatively; an untested test-only control is worse than the
    /// flake it was meant to prevent.
    func reloadPage(_ app: XCUIApplication) {
        app.typeKey("r", modifierFlags: .command)
    }
'''


def remove_func(text: str, name: str) -> tuple[str, bool]:
    match = re.search(
        r"^([ \t]*)(?:@discardableResult\n[ \t]*)?(?:private )?func %s\s*\(" % re.escape(name),
        text, re.M,
    )
    if not match:
        return text, False
    start = match.start()
    line_start = text.rfind("\n", 0, start) + 1
    probe = line_start
    while probe > 0:
        prev = text.rfind("\n", 0, probe - 1) + 1
        line = text[prev:probe].strip()
        if line.startswith(("///", "//", "@")):
            probe = prev
            continue
        break
    start = probe
    brace = text.index("{", match.end() - 1)
    depth, i = 0, brace
    while i < len(text):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                break
        i += 1
    end = i + 1
    while end < len(text) and text[end] == "\n":
        end += 1
    return text[:start] + text[end:], True


if __name__ == "__main__":
    body = open(SUITE).read()

    for name in REMOVE_FUNCS:
        body, ok = remove_func(body, name)
        print(f"  {'removed ' if ok else 'NOT FOUND'} {name}")

    for old, new in REPLACEMENTS:
        count = body.count(old)
        if count == 0:
            print(f"  MISS: {old.strip()[:60]!r}")
        body = body.replace(old, new)
        if count:
            print(f"  re-pointed x{count}: {old.strip().splitlines()[0][:60]}")

    # Append the helpers inside the class: before the last closing brace.
    last = body.rstrip().rfind("\n}")
    body = body[:last] + "\n" + NEW_HELPERS + body[last:]

    if body.count("{") != body.count("}"):
        sys.exit(f"refusing to write: unbalanced braces "
                 f"({body.count('{')} open, {body.count('}')} close)")
    open(SUITE, "w").write(body)

    stale = [
        line for line in body.splitlines()
        if re.search(r'"(more-menu-button|reload-button|url-field|'
                     r'add-workspace-button|tab-overview-button|'
                     r'session-selector-menu|aperture-brand-header)"', line)
    ]
    if stale:
        print("Still referencing removed UI:")
        for line in stale:
            print("  " + line.strip())
    else:
        print("ok: no references to removed UI remain")
