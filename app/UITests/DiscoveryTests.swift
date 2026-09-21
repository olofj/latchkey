// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

//
//  DiscoveryTests.swift
//  LatchkeyUITests
//
//  M5: gateway discovery (revision R26), on the L2 harness.
//
//  The app's real node joins testing/tsnet-harness, started with extra
//  peers, so the tailnet holds exactly the cases discovery must tell apart:
//    gw     forwards to the fake KiroCrew gateway (the real 0.6.0 manifest,
//           and a 403 + X-Auth-Required /api/auth/me): a gateway
//    dash   forwards to dashboard.py, a web page but not KiroCrew
//    plain  nothing listening
//    slow   accepts and never answers: must not stall the sweep
//  All four are online, owned by the same user and report macOS, so all pass
//  R26's filters; the fingerprint alone decides.
//
//  No -UITestHomePage: the app starts with no gateway, as a first run does.
//  Needs scripts/test-discovery.sh (parent repo).
//

import XCTest

@MainActor
final class DiscoveryTests: XCTestCase {

    static let controlURL = "http://127.0.0.1:8490"
    static let harnessAPI = "http://127.0.0.1:8491"
    static let gatewayControl = "http://127.0.0.1:8481"
    static let dashboardControl = "http://127.0.0.1:8480"
    static let gatewayHost = "gw.tail-scale.ts.net"

    override func setUp() async throws {
        continueAfterFailure = false
        guard (try? await Self.get("\(Self.harnessAPI)/healthz")) != nil,
              (try? await Self.get("\(Self.gatewayControl)/__state")) != nil
        else {
            XCTFail("The discovery harness is not running. Use scripts/test-discovery.sh (parent repo).")
            return
        }
        try await resetFakes()
    }

    /// Both fakes forget everything, and are checked to have (M5 review: a
    /// silently failed reset would let an earlier test's probe satisfy a
    /// later test's "was probed" check).
    private func resetFakes() async throws {
        _ = try await Self.post("\(Self.gatewayControl)/__reset")
        _ = try await Self.post("\(Self.dashboardControl)/__reset")
        let paths = try await dashboardState()["paths"] as? [String] ?? ["<unreadable>"]
        let requests = try await gatewayState()["requests"] as? [String] ?? ["<unreadable>"]
        XCTAssertTrue(paths.isEmpty && requests.isEmpty, "the fakes did not reset: \(paths.prefix(3)) \(requests.prefix(3))")
    }

    /// First run: discovery finds exactly the gateway, within R26's budget,
    /// chooses it (the only one), and the dashboard loads it over the tailnet
    /// — reaching the session layer, which asks for a token.
    func testFirstRunFindsExactlyTheGatewayAndLoadsIt() async throws {
        try await resetHarness()
        let app = launch()
        defer { app.terminate() }

        // The picker is up only for the sweep (~1.5 s), too briefly to catch
        // reliably. What proves the result is what follows it: the app
        // chooses a gateway by itself ONLY when exactly one was found. The
        // sweep's timing is R26's app-logged instrument, which
        // scripts/test-discovery.sh enforces from the unified log.
        // Chosen automatically, loaded, and the page asks for a token.
        let sheet = element(app, "token-sheet")
        XCTAssertTrue(sheet.waitForExistence(timeout: 75),
                      "exactly one gateway found, chosen by itself, loaded, and asking for a token")
        XCTAssertTrue(element(app, "token-sheet-target").label.hasSuffix(Self.gatewayHost))

        // The probes really went out: the gateway answered both fingerprint
        // requests, and the non-gateway page was asked too.
        // The probe, in order, before anything else: the manifest, then the
        // unauthenticated /api/auth/me (the page's own calls come after).
        let requests = try await gatewayState()["requests"] as? [String] ?? []
        XCTAssertEqual(Array(requests.prefix(2)), ["GET /manifest.json", "GET /api/auth/me"],
                       "the fingerprint probe came first: \(requests.prefix(6))")
        let dashPaths = try await dashboardState()["paths"] as? [String] ?? []
        XCTAssertTrue(dashPaths.contains { $0.hasPrefix("dash.tail-scale.ts.net GET /manifest.json") },
                      "dash was probed and rejected: \(dashPaths.prefix(5))")
        // The peer that never answers was probed too (its accepts are
        // journaled); plain's refusal shows only in the app's own sweep log,
        // which scripts/test-discovery.sh checks.
        let journal = try await harnessState()["journal"] as? [[String: Any]] ?? []
        XCTAssertTrue(journal.contains { $0["peer"] as? String == "slow" },
                      "the slow peer was probed: \(journal.prefix(5))")
    }

    /// Nothing found: the picker says so, and manual entry works — a bare
    /// name is qualified with the tailnet's suffix and loaded.
    func testManualEntryWhenNoGatewayIsFound() async throws {
        try await resetHarness(withGateway: false)
        let app = launch()
        defer { app.terminate() }

        XCTAssertTrue(element(app, "gateway-picker").waitForExistence(timeout: 60))
        XCTAssertTrue(element(app, "gateway-none").waitForExistence(timeout: 15), "no gateway found, and it says so")
        XCTAssertEqual(element(app, "gateway-sweep-done").label, "sweep-done:0")
        // Not vacuous: the sweep really probed, and rejected, the web page.
        // (A first version passed here with every peer filtered out.)
        let probed = try await dashboardState()["paths"] as? [String] ?? []
        XCTAssertTrue(probed.contains { $0.hasPrefix("dash.tail-scale.ts.net GET /manifest.json") },
                      "dash must have been probed and rejected: \(probed.prefix(5))")

        // "Search again" really sweeps again: dash is probed anew.
        try await resetFakes()
        element(app, "gateway-refresh").tap()
        var reprobed = false
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(500))
            let paths = try await dashboardState()["paths"] as? [String] ?? []
            if paths.contains(where: { $0.hasPrefix("dash.tail-scale.ts.net GET /manifest.json") }) { reprobed = true; break }
        }
        XCTAssertTrue(reprobed, "Search again probes the tailnet again")

        // A host the tailnet does not carry is refused: it would load direct
        // and become the sign-in origin (M5 review).
        let field = element(app, "gateway-manual-field")
        field.tap()
        field.typeText("example.com")
        element(app, "gateway-manual-use").tap()
        XCTAssertTrue(element(app, "gateway-manual-error").waitForExistence(timeout: 5),
                      "a public host is refused, with a reason")
        XCTAssertTrue(element(app, "gateway-picker").exists, "and the picker stays")
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 20))
        field.typeText("dash")
        element(app, "gateway-manual-use").tap()

        // dash.tail-scale.ts.net is the fake dashboard: it reports itself.
        var loaded = false
        for _ in 0..<60 {
            let reports = try await dashboardState()["reports"] as? [String: Any] ?? [:]
            if reports["dash.tail-scale.ts.net"] != nil { loaded = true; break }
            try await Task.sleep(for: .milliseconds(500))
        }
        XCTAssertTrue(loaded, "the manually entered gateway (qualified to its FQDN) loads")
    }

    /// The choice persists: a relaunch goes straight to the gateway, with no
    /// picker.
    func testTheChosenGatewayPersistsAcrossRelaunch() async throws {
        try await resetHarness()
        let app = launch()
        XCTAssertTrue(element(app, "token-sheet").waitForExistence(timeout: 75), "first run: chosen and loaded")
        app.terminate()

        try await resetFakes()
        let again = XCUIApplication()
        again.launchArguments = ["-TestControlURL", Self.controlURL]   // no reset this time
        again.launch()
        defer { again.terminate() }
        XCTAssertTrue(element(again, "token-sheet").waitForExistence(timeout: 60),
                      "the saved gateway loads")
        // Proof it was the SAVED choice: no discovery ran. A sweep would have
        // probed the web-page peer and asked the gateway for its manifest
        // first; re-discovering and auto-choosing gw would otherwise look
        // exactly like persistence (M5 review).
        let dashPaths = try await dashboardState()["paths"] as? [String] ?? []
        XCTAssertFalse(dashPaths.contains { $0.contains("/manifest.json") },
                       "no sweep on a relaunch: dash was probed \(dashPaths.prefix(5))")
        // The page itself fetches /manifest.json (index.html links it), so
        // the mark of a probe is ORDER: a probe asks for the manifest before
        // anything else, a page load starts with GET /.
        let requests = try await gatewayState()["requests"] as? [String] ?? []
        XCTAssertEqual(requests.first, "GET /",
                       "the saved gateway was loaded directly, not probed first: \(requests.prefix(6))")
    }

    /// M5.5: the chosen gateway is gone from the tailnet. The banner's Find
    /// runs a FRESH sweep (not the first run's stale result), and the choice
    /// is applied once the sheet has gone -- the new gateway's token sheet
    /// must still appear, not collide with the closing picker (M5 review).
    func testFindFromTheUnreachableBannerSwitchesGateway() async throws {
        try await resetHarness()
        let app = XCUIApplication()
        app.launchArguments = ["-UITestResetWorkspaces", "-TestControlURL", Self.controlURL,
                               "-UITestHomePage", "https://gone.tail-scale.ts.net"]
        app.launch()
        defer { app.terminate() }

        let find = element(app, "gateway-unreachable-find-button")
        XCTAssertTrue(find.waitForExistence(timeout: 60), "a gateway not in the tailnet: the banner offers Find")
        find.tap()
        let gw = element(app, "gateway-\(Self.gatewayHost)")
        XCTAssertTrue(gw.waitForExistence(timeout: 15), "Find sweeps and lists the gateway")
        gw.tap()
        XCTAssertTrue(element(app, "token-sheet").waitForExistence(timeout: 45),
                      "the new gateway loads, and its token sheet appears after the picker has gone")
        XCTAssertTrue(element(app, "token-sheet-target").label.hasSuffix(Self.gatewayHost))
    }

    // MARK: - Helpers

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestResetWorkspaces", "-TestControlURL", Self.controlURL]
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func resetHarness(withGateway: Bool = true) async throws {
        let data = try await Self.post("\(Self.harnessAPI)/reset\(withGateway ? "" : "?gw=0")", timeout: 90)
        let state = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        XCTAssertNotNil(state["generation"], "reset failed: \(String(decoding: data, as: UTF8.self))")
    }

    private func harnessState() async throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: try await Self.get("\(Self.harnessAPI)/state")) as? [String: Any] ?? [:]
    }

    private func gatewayState() async throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: try await Self.get("\(Self.gatewayControl)/__state")) as? [String: Any] ?? [:]
    }

    private func dashboardState() async throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: try await Self.get("\(Self.dashboardControl)/__state")) as? [String: Any] ?? [:]
    }

    private static func get(_ url: String) async throws -> Data {
        var request = URLRequest(url: URL(string: url)!, timeoutInterval: 5)
        request.httpMethod = "GET"
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    @discardableResult
    private static func post(_ url: String, timeout: TimeInterval = 5) async throws -> Data {
        var request = URLRequest(url: URL(string: url)!, timeoutInterval: timeout)
        request.httpMethod = "POST"
        let (data, _) = try await URLSession.shared.data(for: request)
        return data
    }
}
