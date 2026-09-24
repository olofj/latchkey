#!/usr/bin/env python3
"""Second re-point pass: the helpers that reached into the browser toolbar.

Three helpers survived prune/repoint but still navigate through the compact
toolbar's "More" menu, which PLAN §1.5 deleted:

  waitForBrowserReady  -- used the More button as "is the browser up yet"
  openSettings         -- fell back to the More menu when no gear was visible
  testLogViewerShowsSocksActivity -- same fallback for the Logs entry

All three collapse now that the dashboard carries one gear
(`settings-button`, the same identifier the gate uses) and Settings owns the
Logs row (`logs-button`). Simpler than what they replace.
"""
from __future__ import annotations

import re
import sys

SUITE = "UITests/LatchkeyUITests.swift"

REPLACEMENTS = [
    # "Is the browser up?" — the marker DashboardRootView draws.
    ('''    /// The connected browser is up when its More button is present — that
    /// control only exists in browser chrome after the tailnet has connected.
    @discardableResult
    private func waitForBrowserReady(_ app: XCUIApplication, timeout: TimeInterval = 90) -> Bool {
        app.buttons["more-menu-button"].waitForExistence(timeout: timeout)
    }''',
     '''    /// The dashboard is up when `DashboardRootView`'s connected-browser
    /// marker exists. Upstream waited on the toolbar's More button; that
    /// toolbar is gone (PLAN §1.5) and the marker is the direct signal.
    @discardableResult
    private func waitForBrowserReady(_ app: XCUIApplication, timeout: TimeInterval = 90) -> Bool {
        connectedBrowserMarker(app).waitForExistence(timeout: timeout)
    }'''),

    # Settings: one gear, both states.
    ('''    /// Opens Settings. Settings is reachable two different ways depending on
    /// where we are + the size class:
    ///   - A direct gear button (`settings-button`) in the connection gate
    ///     and the iPad (regular) browser toolbar.
    ///   - A "Settings" item inside the iPhone (compact) browser's "More" menu
    ///     (`more-menu-button` / ellipsis) — there is NO `settings-button` in
    ///     the compact toolbar. This asymmetry is easy to miss (the gate-based
    ///     `testOpenAndCloseSettings` never exercises the menu path).
    @discardableResult
    private func openSettings(_ app: XCUIApplication) -> Bool {
        // Direct gear (gate / iPad).
        if app.buttons["settings-button"].waitForExistence(timeout: 10) {
            app.buttons["settings-button"].tap()
            return app.navigationBars["Settings"].waitForExistence(timeout: 10)
        }
        // Compact browser: Settings lives behind the "More" menu.
        guard app.buttons["more-menu-button"].waitForExistence(timeout: 5) else {
            attachScreenshot(app, named: "settings-no-entry-point")
            return false
        }
        app.buttons["more-menu-button"].tap()
        // SwiftUI Menu items can surface as either `menuItems` or `buttons`.
        let asMenuItem = app.menuItems["Settings"]
        let asButton = app.buttons["Settings"]
        let found = asMenuItem.waitForExistence(timeout: 5)
            || asButton.waitForExistence(timeout: 5)
        guard found else {
            attachScreenshot(app, named: "settings-menu-no-settings-item")
            return false
        }
        (asMenuItem.exists ? asMenuItem : asButton).tap()
        return app.navigationBars["Settings"].waitForExistence(timeout: 10)
    }''',
     '''    /// Opens Settings. There is exactly one entry point now, in both states
    /// and both size classes: the `settings-button` gear — in the connection
    /// gate before connecting, and as `DashboardRootView`'s floating
    /// affordance after. Upstream also had a compact-toolbar "More" menu path;
    /// that toolbar is gone (PLAN §1.5), and so is the asymmetry.
    @discardableResult
    private func openSettings(_ app: XCUIApplication) -> Bool {
        guard app.buttons["settings-button"].waitForExistence(timeout: 10) else {
            attachScreenshot(app, named: "settings-no-entry-point")
            return false
        }
        app.buttons["settings-button"].tap()
        return app.navigationBars["Settings"].waitForExistence(timeout: 10)
    }'''),

    # Logs now live in Settings rather than behind the More menu.
    ('''        // Logs: a toolbar button on iPad (regular), in the "more" menu on iPhone.
        if app.buttons["logs-button"].waitForExistence(timeout: 5) {
            app.buttons["logs-button"].tap()
        } else {
            XCTAssertTrue(app.buttons["more-menu-button"].waitForExistence(timeout: 5),
                          "Either a logs-button or the more-menu should be present")
            app.buttons["more-menu-button"].tap()
            let asMenuItem = app.menuItems["Logs"]
            let asButton = app.buttons["Logs"]
            if asMenuItem.waitForExistence(timeout: 5) { asMenuItem.tap() }
            else if asButton.waitForExistence(timeout: 5) { asButton.tap() }
            else { XCTFail("Logs entry not found in the more menu"); return }
        }''',
     '''        // Logs moved into Settings -> Diagnostics when the toolbar's "more"
        // menu was deleted (PLAN §1.5); that menu was its only entry point.
        XCTAssertTrue(openSettings(app), "Settings should open")
        let logs = app.buttons["logs-button"]
        scrollToElement(logs, in: app)
        XCTAssertTrue(logs.waitForExistence(timeout: 10),
                      "Settings should offer a Logs row")
        logs.tap()'''),
]


if __name__ == "__main__":
    body = open(SUITE).read()
    for old, new in REPLACEMENTS:
        if old not in body:
            print(f"  MISS: {old.strip().splitlines()[0][:70]!r}")
            continue
        body = body.replace(old, new)
        print(f"  re-pointed: {old.strip().splitlines()[0][:70]}")

    if body.count("{") != body.count("}"):
        sys.exit(f"refusing to write: unbalanced braces "
                 f"({body.count('{')} open, {body.count('}')} close)")
    open(SUITE, "w").write(body)

    stale = [
        line.strip() for line in body.splitlines()
        if re.search(r'"(more-menu-button|reload-button|add-workspace-button|'
                     r'tab-overview-button|session-selector-menu|'
                     r'aperture-brand-header)"', line)
    ]
    if stale:
        print("Still referencing removed UI:")
        for line in stale:
            print("  " + line)
        sys.exit(1)
    print("ok: no references to removed UI remain")
