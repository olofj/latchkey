// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

//
//  UITestSupport.swift
//  LatchkeyUITests
//
//  Helpers shared by the suites.
//

import XCTest

/// The harnesses' plain-HTTP control ports, over loopback.
///
/// One implementation, because there were three: each suite had its own private
/// `get`/`post` pair, `get` checked the status code in all three and `post`
/// checked it in none. A `POST /__mode?front=502` aimed at the wrong server
/// therefore returned 404, threw nothing, and the test that depended on it
/// asserted against a perfectly healthy dashboard — then hung for two minutes
/// waiting for an error page that was never going to appear. A control call
/// that does nothing must fail the test that made it.
enum HarnessControl {
    /// Thrown for any non-2xx. Carries the URL because the usual cause is a
    /// path or a port that does not exist on the server being asked.
    struct BadStatus: Error, CustomStringConvertible {
        let method: String
        let url: String
        let status: Int
        let body: String
        var description: String {
            "\(method) \(url) answered \(status), not 2xx"
                + (body.isEmpty ? "" : ": \(body.prefix(200))")
        }
    }

    static func get(_ url: String, timeout: TimeInterval = 5) async throws -> Data {
        try await send("GET", url, timeout: timeout)
    }

    @discardableResult
    static func post(_ url: String, timeout: TimeInterval = 5) async throws -> Data {
        try await send("POST", url, timeout: timeout)
    }

    private static func send(_ method: String, _ url: String,
                             timeout: TimeInterval) async throws -> Data {
        var request = URLRequest(url: URL(string: url)!, timeoutInterval: timeout)
        request.httpMethod = method
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            throw BadStatus(method: method, url: url, status: status,
                            body: String(decoding: data, as: UTF8.self))
        }
        return data
    }
}

extension XCUIElement {
    /// `waitForExistence`, polled every 100 ms. XCTest's own wait first looks
    /// about a second after it starts and then once a second (F14 §4.1,
    /// measured: 1.07 s for an element already on screen), so every wait for
    /// something that is there cost a second, dozens of times per suite. Same
    /// answer, same timeout; only the polling is finer.
    @MainActor
    func appears(within timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !exists {
            if Date() >= deadline { return false }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return true
    }

    /// `waitForNonExistence`, polled the same way.
    @MainActor
    func disappears(within timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while exists {
            if Date() >= deadline { return false }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return true
    }

    /// Scrolls `container` until this element is on screen. Settings opens as
    /// a half sheet, and Forms and Lists build their rows lazily: a row below
    /// the fold is not in the tree until it is scrolled to. Slow swipes, and
    /// back down if one carried the row past the top.
    ///
    /// A row below the fold does not appear by waiting, only by swiping, so
    /// each step waits half a second rather than the two it used to: that wait
    /// was paid in full before every swipe (F14: ~8 s of Status's commit row).
    @MainActor
    func reveal(scrolling container: XCUIElement, swipes: Int = 8) -> Bool {
        for _ in 0..<swipes {
            if appears(within: 0.5), isHittable { return true }
            if exists, frame.maxY < container.frame.midY {
                container.swipeDown(velocity: .slow)
            } else {
                container.swipeUp(velocity: .slow)
            }
        }
        return appears(within: 2) && isHittable
    }
}

extension XCUIApplication {
    /// Settings → Status, from the dashboard's gear.
    @MainActor
    func openStatus(file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        buttons["settings-button"].firstMatch.tap()
        XCTAssertTrue(navigationBars["Settings"].appears(within: 10), "the gear opens Settings",
                      file: file, line: line)
        let status = buttons["status-button"]
        XCTAssertTrue(status.reveal(scrolling: collectionViews.firstMatch), "Settings has a Status entry",
                      file: file, line: line)
        status.tap()
        let list = collectionViews["diagnostics-list"]
        XCTAssertTrue(list.appears(within: 10), "Status opens", file: file, line: line)
        return list
    }

    /// The value of a Status row (`diag-<label>`), scrolled to and settled
    /// (the cookie rows read "reading…", availability "checking", until they
    /// know); a `<missing …>` marker when there is no such row.
    @MainActor
    func statusRow(_ id: String, in list: XCUIElement) -> String {
        let e = list.descendants(matching: .any).matching(identifier: id).firstMatch
        guard e.reveal(scrolling: list) else { return "<missing \(id)>" }
        // Polled rather than an XCTNSPredicateExpectation, which first looks
        // after a second even when the row has long settled.
        let deadline = Date().addingTimeInterval(10)
        var label = e.label
        while label.contains("reading…") || label.hasSuffix("checking"), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
            label = e.label
        }
        return label
    }
}
