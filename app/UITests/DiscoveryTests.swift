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
//  The device-check rehearsal (DEVICE-CHECK.md §3-4) adds the harness's
//  purgatory: every peer drops the app node's traffic until the harness
//  moves its address into the fixture clients range, while it runs.
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

    /// The device-check rehearsal (DEVICE-CHECK.md §3-4). On the real tailnet
    /// a new node lands in a purgatory range with no grants: it connects but
    /// reaches nothing. Olof then moves its address into the kiro-clients
    /// range WHILE IT RUNS (O3b) and taps Search again. Two things had never
    /// been seen before this test: what the picker shows while the node
    /// reaches nothing, and whether the app, its relay and tsnet keep working
    /// after the control plane changes the running node's own address. The
    /// harness's purgatory jails the app's node at every peer (the peers stay
    /// visible; every SYN is dropped), and /move gives it 100.99.1.7.
    func testDeviceCheckRehearsalPurgatoryThenAddressMove() async throws {
        try await resetHarness(purgatory: true)
        let app = launch()
        defer { app.terminate() }

        // 1. In purgatory: the sweep ends, in bounded time, with nothing.
        // The wait here spans the node's start-up too; the sweep's own
        // timing is R26's app-logged instrument, which the script enforces.
        XCTAssertTrue(element(app, "gateway-picker").waitForExistence(timeout: 60), "the first-run picker")
        let shown = ContinuousClock.now
        let none = element(app, "gateway-none")
        XCTAssertTrue(none.waitForExistence(timeout: 20),
                      "the sweep finishes with no gateway; it must not hang on dropped SYNs")
        let waited = ContinuousClock.now - shown
        let message = none.label
        // The peers are visible (as admin devices plausibly are on the real
        // tailnet), so it is the "answered among N" form, not "No computers
        // on your tailnet could be a gateway", which needs an empty list.
        XCTAssertTrue(message.hasPrefix("No Kiro Crew gateway answered among 4 computer(s)"),
                      "in purgatory the picker says: \(message)")
        XCTAssertEqual(element(app, "gateway-sweep-done").label, "sweep-done:0")
        XCTAssertFalse(element(app, "gateway-proxy-unhealthy").exists,
                       "the node's loopback is fine; it is the tailnet that drops the traffic")
        let node = try await appNode()
        XCTAssertTrue(node.jailed, "the harness jails the app's node: \(node)")
        XCTAssertFalse(node.addresses.contains { $0.hasPrefix("100.99.1.") },
                       "a new node lands outside the clients range: \(node.addresses)")
        // Not vacuous: the probes went out and nothing accepted them -- no
        // peer journaled a connection from the app (a dropped SYN is never
        // accepted; a refusal would not be journaled either, but the sweep
        // log's timing tells those apart).
        let before = try await harnessState()["journal"] as? [[String: Any]] ?? []
        XCTAssertFalse(before.contains { Self.isFrom(node.addresses, $0) },
                       "no peer accepted a connection from the jailed node: \(before)")
        XCTContext.runActivity(named: "purgatory: picker showed \(message) after \(waited)") { _ in }

        // 2. O3b: the admin moves the running node into the clients range.
        // The netmap lands within a moment on loopback; Olof's tap comes
        // seconds after the console.
        let to = "100.99.1.7"
        let reply = try JSONSerialization.jsonObject(
            with: try await Self.post("\(Self.harnessAPI)/move?hostname=\(node.hostname)&to=\(to)")) as? [String: Any] ?? [:]
        XCTAssertEqual(reply["moved"] as? Int, 1, "the node was moved: \(reply)")
        try await Task.sleep(for: .seconds(2))
        // Search again, as the runbook has Olof do -- and, as it tells him,
        // once more if a search still finds nothing, rather than reading a
        // single miss as a fault. Found means the gateway row, or already
        // the token sheet: the only gateway on a first run is chosen by
        // itself when the sweep ends (M5.3), about 1.5 s after it is listed
        // (the slow peer's timeout), too brief to catch the row reliably.
        // The sighting is recorded; the proof is what follows.
        let row = element(app, "gateway-\(Self.gatewayHost)")
        let sheet = element(app, "token-sheet")
        var listed = false
        var taps = 0
        repeat {
            element(app, "gateway-refresh").tap()
            taps += 1
            for _ in 0..<40 {
                listed = row.exists || sheet.exists
                if listed { break }
                try await Task.sleep(for: .milliseconds(250))
            }
        } while !listed && taps < 2 && element(app, "gateway-refresh").exists
        XCTAssertTrue(sheet.waitForExistence(timeout: 45),
                      "after the move, Search again finds the gateway, it loads over the tailnet, and asks for a token")
        XCTAssertTrue(element(app, "token-sheet-target").label.hasSuffix(Self.gatewayHost))
        XCTAssertFalse(element(app, "nav-error-overlay").exists, "no navigation error after the address change")
        XCTContext.runActivity(named: "after the move: gateway found = \(listed) after \(taps) tap(s) of Search again") { _ in }

        // 3. The traffic crossed the tailnet from the NEW address: the gw
        // peer journals every connection with its tailnet source. Nothing
        // ever came from the purgatory address (the IPv6 address stays).
        let oldV4 = node.addresses.filter { $0.contains(".") }
        let journal = try await harnessState()["journal"] as? [[String: Any]] ?? []
        XCTAssertTrue(journal.contains { $0["peer"] as? String == "gw" && $0["error"] == nil && Self.isFrom([to], $0) },
                      "gw journaled the app from \(to): \(journal.suffix(6))")
        XCTAssertFalse(journal.contains { Self.isFrom(oldV4, $0) },
                       "nothing came from the purgatory address \(oldV4): \(journal)")
        let after = try await appNode()
        XCTAssertFalse(after.jailed, "released: \(after)")
        XCTAssertTrue(after.addresses.contains(to), "control holds the new address: \(after.addresses)")

        // 4. The app's own view agrees: Status shows the moved address, not
        // the old one (the 5 s status poll has long since run).
        element(app, "token-sheet-close").tap()
        let list = app.openStatus()
        let addresses = app.statusRow("diag-addresses", in: list)
        XCTAssertTrue(addresses.contains(to), "Status shows the moved address: \(addresses)")
        XCTAssertFalse(oldV4.contains { addresses.contains($0) }, "and not the old one: \(addresses)")
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

    private func resetHarness(withGateway: Bool = true, purgatory: Bool = false) async throws {
        var query: [String] = []
        if !withGateway { query.append("gw=0") }
        if purgatory { query.append("purgatory=1") }
        let suffix = query.isEmpty ? "" : "?" + query.joined(separator: "&")
        let data = try await Self.post("\(Self.harnessAPI)/reset\(suffix)", timeout: 90)
        let state = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        XCTAssertNotNil(state["generation"], "reset failed: \(String(decoding: data, as: UTF8.self))")
    }

    private func harnessState() async throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: try await Self.get("\(Self.harnessAPI)/state")) as? [String: Any] ?? [:]
    }

    private struct Node {
        let hostname: String
        let addresses: [String]
        let jailed: Bool
    }

    /// The one node that is not the harness's own: the app's. Waits for it
    /// to register.
    private func appNode() async throws -> Node {
        var last: [[String: Any]] = []
        for _ in 0..<60 {
            last = try await harnessState()["nodes"] as? [[String: Any]] ?? []
            let apps = last.filter { $0["harnessPeer"] as? Bool == false }
            XCTAssertLessThanOrEqual(apps.count, 1, "expected one app node, found \(apps.count): \(apps)")
            if let n = apps.first {
                return Node(hostname: n["hostname"] as? String ?? "",
                            addresses: n["addresses"] as? [String] ?? [],
                            jailed: n["jailed"] as? Bool ?? false)
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        XCTFail("the app's node never registered with the harness; nodes: \(last)")
        return Node(hostname: "", addresses: [], jailed: false)
    }

    /// Whether a journal entry's tailnet source is one of `addresses`.
    private static func isFrom(_ addresses: [String], _ entry: [String: Any]) -> Bool {
        let from = entry["from"] as? String ?? ""
        return addresses.contains { from.hasPrefix("\($0):") || from.hasPrefix("[\($0)]:") }
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
