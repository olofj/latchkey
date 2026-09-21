// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

//
//  UITestSupport.swift
//  LatchkeyUITests
//
//  Helpers shared by the suites.
//

import XCTest

extension XCUIElement {
    /// Scrolls `container` until this element is on screen. Settings opens as
    /// a half sheet, and Forms and Lists build their rows lazily: a row below
    /// the fold is not in the tree until it is scrolled to. Slow swipes, and
    /// back down if one carried the row past the top.
    @MainActor
    func reveal(scrolling container: XCUIElement, swipes: Int = 8) -> Bool {
        for _ in 0..<swipes {
            if waitForExistence(timeout: 2), isHittable { return true }
            if exists, frame.maxY < container.frame.midY {
                container.swipeDown(velocity: .slow)
            } else {
                container.swipeUp(velocity: .slow)
            }
        }
        return exists && isHittable
    }
}

extension XCUIApplication {
    /// Settings → Status, from the dashboard's gear.
    @MainActor
    func openStatus(file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        buttons["settings-button"].firstMatch.tap()
        XCTAssertTrue(navigationBars["Settings"].waitForExistence(timeout: 10), "the gear opens Settings",
                      file: file, line: line)
        let status = buttons["status-button"]
        XCTAssertTrue(status.reveal(scrolling: collectionViews.firstMatch), "Settings has a Status entry",
                      file: file, line: line)
        status.tap()
        let list = collectionViews["diagnostics-list"]
        XCTAssertTrue(list.waitForExistence(timeout: 10), "Status opens", file: file, line: line)
        return list
    }

    /// The value of a Status row (`diag-<label>`), scrolled to and settled
    /// (the cookie rows read "reading…", availability "checking", until they
    /// know); a `<missing …>` marker when there is no such row.
    @MainActor
    func statusRow(_ id: String, in list: XCUIElement) -> String {
        let e = list.descendants(matching: .any).matching(identifier: id).firstMatch
        guard e.reveal(scrolling: list) else { return "<missing \(id)>" }
        let settled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "NOT (label CONTAINS 'reading…') AND NOT (label ENDSWITH 'checking')"),
            object: e)
        _ = XCTWaiter().wait(for: [settled], timeout: 10)
        return e.label
    }
}
