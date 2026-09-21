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
    /// the fold is not in the tree until it is scrolled to.
    @MainActor
    func reveal(scrolling container: XCUIElement, swipes: Int = 6) -> Bool {
        for _ in 0..<swipes {
            if waitForExistence(timeout: 2), isHittable { return true }
            container.swipeUp()
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

    /// The value of a Status row (`diag-<label>`), scrolled to; a
    /// `<missing …>` marker when there is no such row.
    @MainActor
    func statusRow(_ id: String, in list: XCUIElement) -> String {
        let e = list.descendants(matching: .any).matching(identifier: id).firstMatch
        return e.reveal(scrolling: list) ? e.label : "<missing \(id)>"
    }
}
