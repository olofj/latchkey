// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

//
//  TailnetHarnessTests.swift
//  LatchkeyUITests
//
//  L2: the real tsnet node against a fake control plane (PLAN M3, R17).
//
//  Nothing in the app is faked. `-TestControlURL` points the embedded node at
//  testing/tsnet-harness (parent repo), a host process running Tailscale's
//  testcontrol with MagicDNS for tail-scale.ts.net, DERP/STUN on loopback and
//  two real tsnet peers: "dash", which forwards tailnet :443 to the fake
//  dashboard, and "plain", which serves nothing. The node logs in, gets its
//  netmap and DNS config, and WebKit reaches https://dash.tail-scale.ts.net
//  through the node's own loopback SOCKS5 listener.
//
//  Observation is server-side, as in L1 (R13): the page reports to the fake
//  dashboard, and the dash peer journals every tailnet connection with its
//  source address. A journal entry from the APP node's tailnet address is
//  the proof the load crossed the tailnet — dash.tail-scale.ts.net is NXDOMAIN
//  in public DNS, so there is no other way for it to load.
//
//  Needs both harnesses up and the test CA trusted: `scripts/test-tailnet.sh`
//  (parent repo). Endpoints must match testing/tsnet-harness/Makefile.
//

import XCTest

@MainActor
final class TailnetHarnessTests: XCTestCase {

    static let controlURL = "http://127.0.0.1:8490"
    static let harnessAPI = "http://127.0.0.1:8491"
    static let dashboardControl = "http://127.0.0.1:8480"
    static let gateway = "https://dash.tail-scale.ts.net"
    static let gatewayHost = "dash.tail-scale.ts.net"

    /// A cold node's first join takes a few seconds against a loopback
    /// control plane; the page then needs its WebSocket up.
    static let joinTimeout: TimeInterval = 60

    override func setUp() async throws {
        continueAfterFailure = false
        guard (try? await Self.get("\(Self.harnessAPI)/healthz")) != nil,
              (try? await Self.get("\(Self.dashboardControl)/__state")) != nil
        else {
            XCTFail("The L2 harness is not running. Use scripts/test-tailnet.sh (parent repo).")
            return
        }
        _ = try await Self.post("\(Self.dashboardControl)/__reset")
    }

    // MARK: - M3.4 / M3.5: join and load over the tailnet

    /// Open mode: the node joins with no interaction, receives the netmap and
    /// MagicDNS config, and the dashboard loads by name through the node's
    /// loopback SOCKS5 proxy — WebSocket and SSE included.
    func testNodeJoinsTheFakeTailnetAndLoadsTheDashboard() async throws {
        try await resetHarness()
        let app = launch()
        defer { app.terminate() }

        let report = try await waitForReport(timeout: Self.joinTimeout) {
            $0["ws"] as? String == "ws:open" && ($0["echo"] as? String)?.hasPrefix("echo:") == true
                && ($0["sse"] as? String)?.hasPrefix("sse:tick-") == true
        }
        XCTAssertEqual(report["title"] as? String, "FAKE DASHBOARD")

        let node = try await appNode()
        XCTAssertTrue(node.hostname.hasPrefix("latchkey-"), "the app's node registers under its own name; got \(node.hostname)")
        XCTAssertTrue(node.machineAuthorized)
        try await assertJournaled(from: node)
    }

    // MARK: - R17: login and device approval

    /// RequireAuth: the node stops at NeedsLogin, the gate offers Login, and
    /// the harness's login page (reached through the app's real
    /// ASWebAuthenticationSession) completes it. (The "nothing loads" check
    /// here is weak by construction: before login there is no netmap, so the
    /// gateway name cannot even resolve. The approval tests are where it has
    /// teeth — there the node HAS its peers.)
    func testRequireAuthLoginCompletesThroughTheLoginPage() async throws {
        try await resetHarness(auth: true)
        let app = launch()
        defer { app.terminate() }

        let login = app.buttons["login-button"]
        XCTAssertTrue(login.waitForExistence(timeout: Self.joinTimeout), "the gate offers Login at NeedsLogin")
        try await assertNoDashboardLoad(for: 2, "nothing may load before the login")

        login.tap()
        acceptSignInPromptIfShown()

        _ = try await waitForReport(timeout: Self.joinTimeout) { $0["ws"] as? String == "ws:open" }
        let logins = try await harnessState()["logins"] as? [[String: Any]] ?? []
        XCTAssertTrue(logins.contains { $0["completed"] as? Bool == true },
                      "the login completed through the harness's login page; got \(logins)")
        try await assertJournaled(from: try await appNode())
    }

    /// RequireMachineAuth: logged in, but held at NeedsMachineAuth. The gate
    /// says so (no Login button: there is nothing to do in the app), nothing
    /// loads, and approving the device lets the app continue by itself.
    func testNeedsMachineAuthWaitsForApproval() async throws {
        try await resetHarness(machine: true)
        let app = launch()
        defer { app.terminate() }

        let gate = app.descendants(matching: .any).matching(identifier: "needs-machine-auth").firstMatch
        XCTAssertTrue(gate.waitForExistence(timeout: Self.joinTimeout), "the gate explains the pending approval")
        XCTAssertFalse(app.buttons["login-button"].exists, "approval is not a login; no Login button")
        try await assertNoDashboardLoad(for: 3, "nothing may load before approval")

        let node = try await appNode()
        XCTAssertFalse(node.machineAuthorized)
        let approved = try await Self.post("\(Self.harnessAPI)/approve?hostname=\(node.hostname)")
        XCTAssertEqual((try JSONSerialization.jsonObject(with: approved) as? [String: Any])?["approved"] as? Int, 1)

        _ = try await waitForReport(timeout: Self.joinTimeout) { $0["ws"] as? String == "ws:open" }
        try await assertJournaled(from: try await appNode())
    }

    /// Login and then approval, as on a tailnet that requires both: the web
    /// login ends in NeedsMachineAuth, and the gate must say so rather than
    /// "Logged in. Connecting…" — LoginFinished used to hide it there until
    /// the next launch (M3 review). The approval-only test above cannot catch
    /// that: without a login there is no LoginFinished.
    func testLoginThenApprovalShowsTheApprovalGate() async throws {
        try await resetHarness(auth: true, machine: true)
        let app = launch()
        defer { app.terminate() }

        let login = app.buttons["login-button"]
        XCTAssertTrue(login.waitForExistence(timeout: Self.joinTimeout), "the gate offers Login at NeedsLogin")
        login.tap()
        acceptSignInPromptIfShown()

        let gate = app.descendants(matching: .any).matching(identifier: "needs-machine-auth").firstMatch
        XCTAssertTrue(gate.waitForExistence(timeout: Self.joinTimeout),
                      "after the login, the gate explains the pending approval")
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "logged-in-connecting").firstMatch.exists,
                       "not 'Logged in. Connecting…': nothing is connecting until an admin approves")
        let logins = try await harnessState()["logins"] as? [[String: Any]] ?? []
        XCTAssertTrue(logins.contains { $0["completed"] as? Bool == true }, "the login completed; got \(logins)")
        try await assertNoDashboardLoad(for: 3, "nothing may load before approval")

        let node = try await appNode()
        XCTAssertFalse(node.machineAuthorized)
        _ = try await Self.post("\(Self.harnessAPI)/approve?hostname=\(node.hostname)")
        _ = try await waitForReport(timeout: Self.joinTimeout) { $0["ws"] as? String == "ws:open" }
        try await assertJournaled(from: try await appNode())
    }

    // MARK: - M8.2 / M8.3 (R29): diagnostics, before the device tests need them

    /// With a real node on the fake tailnet: Status shows the node, the
    /// gateway and the proxy as they are; the Node log shows tsnet's own
    /// lines -- which, before M8.3, were drained and discarded.
    func testDiagnosticsShowTheNodeAndItsLog() async throws {
        try await resetHarness()
        let app = launch(extra: ["-UITestResetNodeLog"])
        defer { app.terminate() }
        _ = try await waitForReport(timeout: Self.joinTimeout) { $0["ws"] as? String == "ws:open" }

        // Through the dashboard's gear, which was dead until this test: it
        // was faded with .opacity on the button, and over the web view such
        // a button takes no taps.
        let list = app.openStatus()
        func row(_ id: String) -> String { app.statusRow(id, in: list) }
        XCTAssertTrue(row("diag-state").contains("Running"), row("diag-state"))
        XCTAssertTrue(row("diag-tailnet").contains("tail-scale.ts.net"), row("diag-tailnet"))
        XCTAssertTrue(row("diag-gateway").contains(Self.gatewayHost), row("diag-gateway"))
        XCTAssertTrue(row("diag-in-the-tailnet").hasSuffix("yes"), row("diag-in-the-tailnet"))
        let endpoint = row("diag-endpoint")
        XCTAssertNotNil(endpoint.firstMatch(of: /(^|[ ,])127\.0\.0\.1:[0-9]+$/),
                        "the SOCKS endpoint as host:port only -- never a credential: \(endpoint)")
        app.buttons["diagnostics-done-button"].tap()

        let nodeLog = app.buttons["node-log-button"]
        XCTAssertTrue(nodeLog.reveal(scrolling: app.collectionViews.firstMatch), "Settings has a Node log entry")
        nodeLog.tap()
        let filter = app.textFields["node-log-filter"]
        XCTAssertTrue(filter.waitForExistence(timeout: 10))
        let count = app.staticTexts["node-log-count"]
        func setFilter(_ text: String) {
            filter.tap()
            let current = filter.value as? String ?? ""
            let n = current == filter.placeholderValue ? 0 : current.count
            filter.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: n) + text)
        }
        func shownCount() -> Int { Int(count.label.split(separator: " ").first ?? "") ?? -1 }
        setFilter("magicsock:")
        // A line tsnet itself logged, from this launch (the logs were
        // reset). The process's raw stderr -- which under XCTest echoes what
        // the test types, filter text included -- never goes in tsnet.log.
        let tsnetLine = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'magicsock:'")).firstMatch
        XCTAssertTrue(tsnetLine.waitForExistence(timeout: 10),
                      "tsnet's own magicsock lines reach the node log: \(app.staticTexts["node-log-count"].label)")

        // Raw stderr never lands in tsnet.log. Under XCTest the process's
        // stderr is busy -- an unsplit writer put thousands of RAW-STDERR
        // lines here -- so a count of zero means something.
        setFilter("RAW-STDERR")
        XCTAssertEqual(shownCount(), 0, "raw stderr stays out of tsnet's log: \(count.label)")

        // Under XCTest os_log is mirrored to stderr, so raw stderr is a copy
        // of the unified log and is not kept (the vendored writer's rule).
        // tsnet.log records the decision.
        setFilter("raw stderr")
        let decision = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'raw stderr not kept'")).firstMatch
        XCTAssertTrue(decision.waitForExistence(timeout: 10),
                      "the node log says the mirrored stderr is not kept: \(count.label)")

        // The view follows the log: state changes the harness causes now, with
        // the view open, appear without reopening it (the 2-s reread).
        setFilter("Switching ipn state")
        let before = shownCount()
        XCTAssertGreaterThan(before, 0, "startup's own state changes are there: \(count.label)")
        let node = try await appNode()
        _ = try await Self.post("\(Self.harnessAPI)/deauthorize?hostname=\(node.hostname)")
        _ = try await Self.post("\(Self.harnessAPI)/approve?hostname=\(node.hostname)")
        var after = before
        for _ in 0..<15 where after < before + 2 {
            try await Task.sleep(for: .seconds(1))
            after = shownCount()
        }
        XCTAssertGreaterThanOrEqual(after, before + 2,
                                    "two new state changes appear while the view is open: \(before) -> \(count.label)")

        // The stderr source: nothing, since it is not kept here.
        app.segmentedControls["node-log-source"].buttons["stderr"].tap()
        XCTAssertTrue(app.staticTexts["Nothing on stderr"].waitForExistence(timeout: 10),
                      "nothing of the unified log's mirror is on disk: \(count.label)")
    }

    // MARK: - R31: key expiry and approval, mid-session

    /// The node key expires in 10 days: the dashboard warns (14 days ahead)
    /// without anyone opening Settings.
    func testAKeyAboutToExpireIsWarnedAbout() async throws {
        try await resetHarness()
        let app = launch()
        defer { app.terminate() }
        _ = try await waitForReport(timeout: Self.joinTimeout) { $0["ws"] as? String == "ws:open" }
        // The KEY's warning: on a device a near-expiry provisioning profile
        // adds a warning of its own (R31 review).
        let warning = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == 'expiry-warning' AND label CONTAINS 'Tailscale key'")).firstMatch
        XCTAssertFalse(warning.exists, "no key expiry yet: no warning")

        let node = try await appNode()
        _ = try await Self.post("\(Self.harnessAPI)/expire?hostname=\(node.hostname)&in=\(10 * 86400)")
        XCTAssertTrue(warning.waitForExistence(timeout: 20), "a key expiring in 10 days is warned about")
        XCTAssertTrue(warning.label.contains("expires in 9 days") || warning.label.contains("expires in 10 days"),
                      "and says when: \(warning.label)")
    }

    /// The key expires mid-session (as the admin console's "Expire key" or a
    /// real expiry date does it): the dashboard stays, the Login banner offers
    /// a new login, and the login brings the node back.
    func testAnExpiredKeyMidSessionAsksForLoginAgain() async throws {
        try await resetHarness(auth: true)
        let app = launch()
        defer { app.terminate() }
        let login = app.buttons["login-button"]
        XCTAssertTrue(login.waitForExistence(timeout: Self.joinTimeout), "the gate offers Login at NeedsLogin")
        login.tap()
        acceptSignInPromptIfShown()
        _ = try await waitForReport(timeout: Self.joinTimeout) { $0["ws"] as? String == "ws:open" }
        let loginsBefore = try await completedLogins()

        let node = try await appNode()
        _ = try await Self.post("\(Self.harnessAPI)/expire?hostname=\(node.hostname)&in=-60")
        let again = app.buttons["login-banner-button"]
        XCTAssertTrue(again.waitForExistence(timeout: 30), "an expired key: the dashboard offers Login")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "connected-browser").firstMatch.exists,
                      "on the dashboard -- the app does not drop back to the gate")
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "expiry-warning").firstMatch.exists,
                       "the Login banner says it; no second, stale expiry warning")

        again.tap()
        acceptSignInPromptIfShown()
        XCTAssertTrue(again.waitForNonExistence(timeout: Self.joinTimeout), "the new login ends the banner")
        let loginsAfter = try await completedLogins()
        XCTAssertGreaterThan(loginsAfter, loginsBefore, "a NEW login completed through the harness's login page")
        let state = nodeState(app)
        XCTAssertTrue(state.hasSuffix("Running"), "and the node is back on the tailnet: \(state)")
    }

    /// An admin revokes the device's approval mid-session: the dashboard says
    /// it is waiting for approval (there is nothing to do in the app), and
    /// comes back by itself when the device is approved again.
    func testARevokedDeviceMidSessionWaitsForApproval() async throws {
        try await resetHarness()
        let app = launch()
        defer { app.terminate() }
        _ = try await waitForReport(timeout: Self.joinTimeout) { $0["ws"] as? String == "ws:open" }
        let node = try await appNode()

        _ = try await Self.post("\(Self.harnessAPI)/deauthorize?hostname=\(node.hostname)")
        let banner = app.descendants(matching: .any).matching(identifier: "needs-machine-auth-banner").firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 30), "the dashboard says the device awaits approval")
        XCTAssertFalse(app.buttons["login-banner-button"].exists, "approval is not a login: no Login button")

        let approved = try await Self.post("\(Self.harnessAPI)/approve?hostname=\(node.hostname)")
        XCTAssertEqual((try JSONSerialization.jsonObject(with: approved) as? [String: Any])?["approved"] as? Int, 1)
        XCTAssertTrue(banner.waitForNonExistence(timeout: 30), "approved again: the banner goes by itself")
        let state = nodeState(app)
        XCTAssertTrue(state.hasSuffix("Running"), "and the node is back: \(state)")
    }

    // MARK: - R32: a reset removes the node, not just the app's copy

    /// Settings → Reset expires the node's key AT CONTROL (LocalAPI /logout)
    /// before deleting anything, so no orphan with a valid key stays behind
    /// in the admin console. Upstream's logout (a local-only deleteProfile)
    /// would pass every app-side check and fail this one.
    ///
    /// Named to sort EARLY (XCTest orders case-insensitively): a reset deletes
    /// the node logs, and scripts/test-tailnet.sh's login-link scan proves
    /// itself on the redacted link the LAST test (a login) leaves in tsnet.log.
    func testAResetExpiresTheNodeAtControl() async throws {
        try await resetHarness()
        let app = launch()
        defer { app.terminate() }
        _ = try await waitForReport(timeout: Self.joinTimeout) { $0["ws"] as? String == "ws:open" }
        let node = try await appNode()
        let expiredBefore = try await nodeKeyExpired(hostname: node.hostname)
        XCTAssertFalse(expiredBefore, "a fresh node's key is valid")

        app.buttons["settings-button"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        let reset = app.buttons["reset-app-button"]
        XCTAssertTrue(reset.reveal(scrolling: app.collectionViews.firstMatch), "Settings offers Reset")
        reset.tap()
        let confirm = app.alerts.buttons["Reset"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "a reset asks first")
        confirm.tap()

        var expired = false
        for _ in 0..<30 where !expired {
            try await Task.sleep(for: .seconds(1))
            expired = try await nodeKeyExpired(hostname: node.hostname)
        }
        XCTAssertTrue(expired, "the reset node's key is expired at control, not just forgotten here")
    }

    /// Whether control holds an EXPIRED key for a node of this name (a node
    /// that logged out; a new one of the same name may have joined since).
    private func nodeKeyExpired(hostname: String) async throws -> Bool {
        let nodes = try await harnessState()["nodes"] as? [[String: Any]] ?? []
        return nodes.contains { $0["hostname"] as? String == hostname && $0["keyExpired"] as? Bool == true }
    }

    /// The node's state as the app itself reports it (Settings → Status):
    /// the harness can see registrations and approvals, not a client's state.
    /// Waits for Running, up to the join timeout -- after a re-login the node
    /// needs its new netmap and a fresh DERP connection first (R31 review) --
    /// and returns what the row last said.
    private func nodeState(_ app: XCUIApplication) -> String {
        let list = app.openStatus()
        let row = list.descendants(matching: .any).matching(identifier: "diag-state").firstMatch
        var state = app.statusRow("diag-state", in: list)
        let running = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label ENDSWITH 'Running'"), object: row)
        if XCTWaiter().wait(for: [running], timeout: Self.joinTimeout) == .completed { state = row.label }
        app.buttons["diagnostics-done-button"].tap()
        app.buttons["settings-done-button"].firstMatch.tap()
        return state
    }

    private func completedLogins() async throws -> Int {
        (try await harnessState()["logins"] as? [[String: Any]] ?? []).filter { $0["completed"] as? Bool == true }.count
    }

    // MARK: - Launch

    private func launch(extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-UITestResetWorkspaces",
            "-UITestHomePage", Self.gateway,
            "-TestControlURL", Self.controlURL,
        ] + extra
        app.launch()
        return app
    }

    /// With prefersEphemeralWebBrowserSession iOS normally skips the "wants to
    /// use … to Sign In" prompt; accept it if a release shows it anyway.
    private func acceptSignInPromptIfShown() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let proceed = springboard.buttons["Continue"]
        if proceed.waitForExistence(timeout: 3) { proceed.tap() }
    }

    // MARK: - Harness (testing/tsnet-harness)

    private func resetHarness(auth: Bool = false, machine: Bool = false) async throws {
        let data = try await Self.post("\(Self.harnessAPI)/reset?auth=\(auth ? 1 : 0)&machine=\(machine ? 1 : 0)",
                                       timeout: 90)
        let state = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        XCTAssertNotNil(state["generation"], "reset failed: \(String(decoding: data, as: UTF8.self))")
    }

    private func harnessState() async throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: try await Self.get("\(Self.harnessAPI)/state")) as? [String: Any] ?? [:]
    }

    private struct Node {
        let hostname: String
        let addresses: [String]
        let machineAuthorized: Bool
    }

    /// The one node that is not the harness's own: the app's. Waits for it to
    /// register.
    private func appNode() async throws -> Node {
        var last: [[String: Any]] = []
        for _ in 0..<60 {
            last = try await harnessState()["nodes"] as? [[String: Any]] ?? []
            let apps = last.filter { $0["harnessPeer"] as? Bool == false }
            if apps.count > 1 {
                XCTFail("expected one app node, found \(apps.count): \(apps)")
            }
            if let n = apps.first {
                return Node(hostname: n["hostname"] as? String ?? "",
                            addresses: n["addresses"] as? [String] ?? [],
                            machineAuthorized: n["machineAuthorized"] as? Bool ?? false)
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw HarnessError("the app's node never registered with the harness; nodes: \(last)")
    }

    private struct HarnessError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    /// The dash peer saw a connection from the app node's tailnet address:
    /// the load went through the node, not around it.
    private func assertJournaled(from node: Node,
                                 file: StaticString = #filePath, line: UInt = #line) async throws {
        let journal = try await harnessState()["journal"] as? [[String: Any]] ?? []
        let fromApp = journal.filter { e in
            e["peer"] as? String == "dash" && e["error"] == nil
                && node.addresses.contains { addr in
                    let from = e["from"] as? String ?? ""
                    return from.hasPrefix("\(addr):") || from.hasPrefix("[\(addr)]:")
                }
        }
        XCTAssertFalse(fromApp.isEmpty,
                       "the dash peer must journal a connection from the app node \(node.addresses); journal: \(journal)",
                       file: file, line: line)
    }

    // MARK: - Dashboard (testing/harness/dashboard.py)

    private func assertNoDashboardLoad(for seconds: Double, _ message: String,
                                       file: StaticString = #filePath, line: UInt = #line) async throws {
        try await Task.sleep(for: .seconds(seconds))
        let state = try JSONSerialization.jsonObject(
            with: try await Self.get("\(Self.dashboardControl)/__state")) as? [String: Any] ?? [:]
        let requests = state["requests"] as? [String: Int] ?? [:]
        XCTAssertEqual(requests[Self.gatewayHost] ?? 0, 0, "\(message); saw \(requests)", file: file, line: line)
        // The dash peer journals every tailnet connection, including one that
        // fails TLS or never sends a request the dashboard would count.
        let journal = try await harnessState()["journal"] as? [[String: Any]] ?? []
        let dash = journal.filter { $0["peer"] as? String == "dash" }
        XCTAssertTrue(dash.isEmpty, "\(message): the dash peer saw tailnet connections \(dash)",
                      file: file, line: line)
    }

    private func waitForReport(timeout: TimeInterval,
                               until predicate: ([String: Any]) -> Bool) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        var last: [String: Any] = [:]
        while Date() < deadline {
            let state = try JSONSerialization.jsonObject(
                with: try await Self.get("\(Self.dashboardControl)/__state")) as? [String: Any] ?? [:]
            if let r = (state["reports"] as? [String: [String: Any]])?[Self.gatewayHost] {
                last = r
                if predicate(r) { return r }
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        XCTFail("no matching report from \(Self.gatewayHost) within \(Int(timeout))s; last: \(last)")
        return last
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
