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
        _ = try await Self.post("\(Self.gatewayControl)/__reset")
        _ = try await Self.post("\(Self.dashboardControl)/__reset")
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
        let requests = try await gatewayState()["requests"] as? [String] ?? []
        XCTAssertTrue(requests.contains("GET /manifest.json"), "the gateway was probed: \(requests.prefix(10))")
        XCTAssertTrue(requests.contains("GET /api/auth/me"), "and its auth probe was made")
        let dashPaths = try await dashboardState()["paths"] as? [String] ?? []
        XCTAssertTrue(dashPaths.contains { $0.hasPrefix("dash.tail-scale.ts.net GET /manifest.json") },
                      "dash was probed and rejected: \(dashPaths.prefix(5))")
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

        let field = element(app, "gateway-manual-field")
        field.tap()
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

        _ = try await Self.post("\(Self.gatewayControl)/__reset")
        let again = XCUIApplication()
        again.launchArguments = ["-TestControlURL", Self.controlURL]   // no reset this time
        again.launch()
        defer { again.terminate() }
        XCTAssertTrue(element(again, "token-sheet").waitForExistence(timeout: 60),
                      "the saved gateway loads directly")
        XCTAssertFalse(element(again, "gateway-picker").exists, "no picker on a relaunch")
        let shells = ((try await gatewayState())["counters"] as? [String: Int])?["shell_loads"] ?? 0
        XCTAssertGreaterThan(shells, 0, "the saved gateway was loaded")
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
