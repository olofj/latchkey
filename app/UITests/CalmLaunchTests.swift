// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

//
//  CalmLaunchTests.swift
//  LatchkeyUITests
//
//  F21: a cold launch against KiroCrew's REAL pinned 0.7.1 frontend never
//  paints the shell's dark default on a light phone. The shell ships
//  `<html data-theme="dark">` and chooses its theme only after its module
//  graph has booted; the app's calm shell (`PageScriptSources.calmShell`)
//  keeps that unresolved shell from painting.
//
//  The instrument is `page-background-reports`, every canvas colour the
//  page reported since its document committed (`-UITestReportPageBackgrounds`,
//  `PageBackgroundInstrument.swift`), sampled by the page every frame for
//  the document's first three seconds.
//
//  The simulator must be in light appearance, as simulators are by default:
//  the control says so when it is not.
//
//  Needs the offline harness AND the fake gateway: scripts/test-session.sh.
//

import XCTest

@MainActor
final class CalmLaunchTests: XCTestCase {

    static let gatewayControl = SessionTests.gatewayControl
    static let proxyControl = SessionTests.proxyControl
    static let gateway = SessionTests.gateway

    override func setUp() async throws {
        continueAfterFailure = false
        guard (try? await HarnessControl.get("\(Self.gatewayControl)/__state")) != nil,
              (try? await HarnessControl.get("\(Self.proxyControl)/journal")) != nil
        else {
            XCTFail("The fake gateway or the offline harness is not running. Use scripts/test-session.sh (parent repo).")
            return
        }
        try await HarnessInstance.assertIsOurs("\(Self.gatewayControl)/__state")
        try await HarnessInstance.assertIsOurs("\(Self.proxyControl)/state")
        try await HarnessControl.post("\(Self.gatewayControl)/__reset")
        try await HarnessControl.post("\(Self.proxyControl)/mode?blackhole=0")
        try await HarnessControl.post("\(Self.proxyControl)/open")
    }

    /// F21 §6: with the calm shell, every canvas the page paints is on the
    /// side of the one it settles on: the unresolved shell paints nothing
    /// (`""`; the web view's own backing shows), then the chosen theme.
    func testTheRealDashboardNeverPaintsItsDarkShellFirst() async throws {
        let (app, reports) = try await launchAndSettleTheShell()
        defer { app.terminate() }
        let opaque = reports.compactMap { Self.brightness($0) }
        let settled = try XCTUnwrap(opaque.last, "the page reported an opaque canvas: \(reports)")
        for b in opaque {
            XCTAssertEqual(b > 128, settled > 128,
                           "every canvas the page painted is on the side it settled on (\(settled)); got \(reports)")
        }
    }

    /// The control: without the calm shell the same launch reports the
    /// bundle's dark default first and the light theme after, so the
    /// instrument sees the flash it exists to see. On a simulator in dark
    /// appearance this fails and says so: the shell's default is then the
    /// chosen side, and there is no flash to catch.
    func testWithoutTheCalmShellTheRealDashboardPaintsDarkFirst() async throws {
        let (app, reports) = try await launchAndSettleTheShell(extra: ["-UITestNoCalmShell"])
        defer { app.terminate() }
        let opaque = reports.compactMap { Self.brightness($0) }
        let first = try XCTUnwrap(opaque.first, "the page reported an opaque canvas: \(reports)")
        let settled = try XCTUnwrap(opaque.last)
        XCTAssertGreaterThan(settled, 128,
                             "the page settles on its light theme (is the simulator in light appearance?); got \(reports)")
        XCTAssertLessThan(first, 128, "the bundle's own first paint is its dark shell; got \(reports)")
    }

    // MARK: - Helpers

    /// Launches signed out (the flash precedes session state, F21 §9),
    /// closes the sheet so the instrument below it is readable, and waits
    /// until the page has reported an opaque canvas and kept it for 3 s.
    ///
    /// Every `/assets/` file is held 50 ms first: over loopback the bundle's
    /// module graph boots before its shell gets a frame on screen (F21 §9),
    /// while the phone's tailnet path gave the shell a quarter of a second.
    /// Six connections paying 50 ms each over some seventy files is a few
    /// hundred ms of shell.
    private func launchAndSettleTheShell(extra: [String] = []) async throws -> (XCUIApplication, [String]) {
        try await HarnessControl.post("\(Self.gatewayControl)/__slow?assets=0.05")
        let app = XCUIApplication()
        app.launchArguments = [
            "-UITestResetWorkspaces",
            "-UITestHomePage", Self.gateway,
            "-TestStatusFixture", OfflineHarnessTests.fixture(suffix: "tail-scale.ts.net", peers: ["gw"]),
            "-TestProxyEndpoint", OfflineHarnessTests.proxyEndpoint,
            "-TestProxyCredential", OfflineHarnessTests.proxyCredential,
            // test-session.sh's R1 scan reads every test's web data.
            "-UITestKeepWebData",
            "-UITestReportPageBackgrounds",
        ] + extra
        app.launch()
        XCTAssertTrue(element(app, "token-sheet").appears(within: 30), "the dashboard is up and asked to sign in")
        element(app, "token-sheet-close").tapWhenSettled(in: app)
        var reports = backgroundReports(app), stableFor = 0
        for _ in 0..<30 {
            try await Task.sleep(for: .seconds(1))
            let now = backgroundReports(app)
            if now == reports, now.last.flatMap({ Self.brightness($0) }) != nil { stableFor += 1 } else { stableFor = 0 }
            reports = now
            if stableFor >= 3 { break }
        }
        return (app, reports)
    }

    /// The canvas colours the page reported since its document committed,
    /// in order: `""` for a canvas that paints nothing, else WebKit's
    /// `rgb(r, g, b)`.
    private func backgroundReports(_ app: XCUIApplication) -> [String] {
        let marker = element(app, "page-background-reports")
        guard marker.appears(within: 5) else { return [] }
        let label = marker.label
        guard let range = label.range(of: "page-backgrounds:") else { return [] }
        let list = label[range.upperBound...]
        return list.isEmpty ? [] : list.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
    }

    /// Mean channel of an opaque `rgb(r, g, b)` report, 0…255; nil for
    /// anything else. Above 128 is a light canvas: kiro-light's is 255, the
    /// shell's dark default 21.
    private static func brightness(_ css: String) -> Double? {
        guard css.hasPrefix("rgb("), css.hasSuffix(")") else { return nil }
        let parts = css.dropFirst(4).dropLast().split(separator: ",")
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 3 else { return nil }
        return parts.reduce(0, +) / 3
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
}
