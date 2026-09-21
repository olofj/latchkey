// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

//
//  OfflineHarnessTests.swift
//  LatchkeyUITests
//
//  L1: the offline harness (PLAN M2, revisions R10, R11, R13).
//
//  The real app, a real WKWebView, the production proxy path — pointed at a
//  stub SOCKS5 proxy and a fake dashboard on loopback, with no Tailscale
//  account, node or network. Each test launches the app with
//  `-TestStatusFixture` (R11): no tsnet node starts, the fixture status and
//  `.Running` go onto the model, and everything above it —
//  `TSNetManager.proxyConfig`, `ProxyConfigurationFactory`,
//  `TailnetProxyPolicy`, `loadInitial`, `HomePageAvailability`, the navigation
//  policy — runs unmodified.
//
//  Observation is server-side (R13): the page reports its state to the fake
//  dashboard, which counts requests per Host, and the stub proxy journals
//  every CONNECT. The tests read both over plain HTTP on 127.0.0.1. Only the
//  app's own native UI (the error page) is read from the accessibility tree.
//
//  Needs the harness running and the test CA trusted in the simulator:
//  `scripts/test-offline.sh` (parent repo) does both, and fails fast if not.
//  Endpoints must match testing/harness/Makefile's defaults.
//
//  Never use a real tailnet name or address here (R10): on a machine running
//  Tailscale, a leak to one would SUCCEED through the host's VPN.
//

import XCTest

@MainActor
final class OfflineHarnessTests: XCTestCase {

    // MARK: - Harness endpoints (testing/harness/Makefile)

    static let proxyEndpoint = "127.0.0.1:1080"
    static let proxyCredential = "s3cret"
    static let dashboardControl = "http://127.0.0.1:8480"
    static let proxyControl = "http://127.0.0.1:1081"

    /// The fixture tailnet. Public DNS answers NXDOMAIN for it, so its names
    /// can only ever load through the proxy.
    static let tailnetSuffix = "tail-scale.ts.net"
    static let gateway = "https://dash.tail-scale.ts.net"
    /// A PUBLIC name resolving to 127.0.0.1 and ::1, served by the same fake
    /// dashboard. The anti-leak origin (R10): a leaked direct connection to it
    /// would succeed, so a leak is detectable.
    static let leakOrigin = "https://dash.localtest.me:8443"

    override func setUp() async throws {
        continueAfterFailure = false
        // Fail fast with a useful message when the harness is not up, instead
        // of every test timing out on a page that can never load.
        guard (try? await Self.get("\(Self.dashboardControl)/__state")) != nil,
              (try? await Self.get("\(Self.proxyControl)/journal")) != nil
        else {
            XCTFail("Offline harness is not running. Use scripts/test-offline.sh (parent repo).")
            return
        }
        _ = try await Self.post("\(Self.dashboardControl)/__reset")
        _ = try await Self.post("\(Self.proxyControl)/reset")
        _ = try await Self.post("\(Self.proxyControl)/mode?blackhole=0")
        _ = try await Self.post("\(Self.proxyControl)/open")
    }

    // MARK: - M2.5 / M2.7: the happy path

    /// The dashboard loads through the proxy, its WebSocket echoes, its SSE
    /// stream advances, and the proxy journal shows the CONNECT — proof the
    /// traffic went through the proxy rather than reaching the server some
    /// other way.
    func testDashboardLoadsThroughTheProxy() async throws {
        let app = launch(gateway: Self.gateway, suffix: Self.tailnetSuffix,
                         peers: ["dash"])
        defer { app.terminate() }

        let report = try await waitForReport(host: "dash.tail-scale.ts.net", timeout: 30) {
            $0["ws"] as? String == "ws:open"
                && ($0["echo"] as? String)?.hasPrefix("echo:") == true
                && Self.sseTick($0) != nil
        }
        XCTAssertEqual(report["title"] as? String, "FAKE DASHBOARD")
        XCTAssertEqual(report["echo"] as? String, "echo:echo:ping", "the WebSocket echoes through TLS through SOCKS5")

        let first = try XCTUnwrap(Self.sseTick(report), "an SSE tick has arrived")
        let later = try await waitForReport(host: "dash.tail-scale.ts.net", timeout: 10) {
            (Self.sseTick($0) ?? -1) > first
        }
        XCTAssertGreaterThan(Self.sseTick(later) ?? -1, first, "the SSE stream advances")

        let connects = try await journalConnects()
        XCTAssertTrue(connects.contains { $0.host == "dash.tail-scale.ts.net" && $0.port == 443 },
                      "the proxy journal must show the CONNECT; got \(connects)")
    }

    // MARK: - R10 / R11: the anti-leak pair

    /// Positive control AND the split-tunnel assertion (R10 step 1, R11): with
    /// localtest.me outside the tailnet, the same origin the negative test
    /// uses loads DIRECT and never touches the proxy. This proves a leak to
    /// that origin would succeed, which is what makes the negative tests
    /// meaningful.
    func testNonTailnetOriginLoadsDirectAndNeverTouchesTheProxy() async throws {
        let app = launch(gateway: Self.leakOrigin, suffix: Self.tailnetSuffix, peers: ["dash"])
        defer { app.terminate() }

        _ = try await waitForReport(host: "dash.localtest.me", timeout: 30) {
            $0["title"] as? String == "FAKE DASHBOARD"
        }
        let connects = try await journalConnects()
        XCTAssertFalse(connects.contains { $0.host == "dash.localtest.me" },
                       "a non-tailnet origin must load direct, never through the proxy; got \(connects)")
    }

    /// R10 step 2: localtest.me IS the tailnet here, so the origin is proxied,
    /// and the proxy refuses every CONNECT. The load must fail, the journal
    /// must show the attempt, and the dashboard must have received ZERO
    /// requests — no direct fallback.
    func testBlackholedProxyFailsWithoutDirectFallback() async throws {
        _ = try await Self.post("\(Self.proxyControl)/mode?blackhole=1")
        let app = launch(gateway: Self.leakOrigin, suffix: "localtest.me", peers: ["dash"])
        defer { app.terminate() }

        try assertErrorPage(app, "a blackholed proxy must fail the load")
        let connects = try await journalConnects()
        XCTAssertTrue(connects.contains { $0.host == "dash.localtest.me" },
                      "the attempt must have reached the proxy; got \(connects)")
        try await assertZeroRequests(host: "dash.localtest.me")
    }

    /// R10 variant: the proxy is gone (its listener closed), with the app's
    /// logging relay in front as in production. The relay cannot reach it.
    func testProxyGoneFailsWithoutDirectFallback() async throws {
        _ = try await Self.post("\(Self.proxyControl)/close")
        let app = launch(gateway: Self.leakOrigin, suffix: "localtest.me", peers: ["dash"])
        defer { app.terminate() }

        try assertErrorPage(app, "an unreachable proxy must fail the load")
        try await assertZeroRequests(host: "dash.localtest.me")
    }

    /// R10 variant without the relay (-NoSocksLog): WebKit's proxy is the
    /// dead stub itself. With the relay on, WebKit always talks to an in-app
    /// listener, which masks exactly the proxy-unreachable path that
    /// `allowFailover == false` governs.
    func testProxyGoneWithoutRelayFailsWithoutDirectFallback() async throws {
        _ = try await Self.post("\(Self.proxyControl)/close")
        let app = launch(gateway: Self.leakOrigin, suffix: "localtest.me", peers: ["dash"],
                         extra: ["-NoSocksLog"])
        defer { app.terminate() }

        try assertErrorPage(app, "an unreachable proxy must fail the load even without the relay")
        try await assertZeroRequests(host: "dash.localtest.me")
    }

    // MARK: - The error page (coverage lost with the address bar in M1)

    /// A certificate that does not name the host fails the load onto the
    /// app's error page, instead of loading or hanging.
    func testCertificateNameMismatchShowsTheErrorPage() async throws {
        let app = launch(gateway: "https://wrong.tail-scale.ts.net", suffix: Self.tailnetSuffix,
                         peers: ["dash", "wrong"])
        defer { app.terminate() }
        try assertErrorPage(app, "a certificate for the wrong name must not load")
    }

    /// A gateway that refuses connections shows the error page.
    func testUnreachableGatewayShowsTheErrorPage() async throws {
        let app = launch(gateway: "https://down.tail-scale.ts.net", suffix: Self.tailnetSuffix,
                         peers: ["dash", "down"])
        defer { app.terminate() }
        try assertErrorPage(app, "a refused connection must show the error page")
    }

    // MARK: - R3 review: a blocked redirect keeps the dashboard

    /// A same-origin link that redirects to another origin: the navigation
    /// policy cancels it mid-flight and hands it to Safari. WebKit reports
    /// that as WebKitErrorDomain 102, which must not paint the error page over
    /// a working dashboard.
    func testRedirectToAnotherOriginLeavesTheAppAndKeepsTheDashboard() async throws {
        let app = launch(gateway: Self.gateway, suffix: Self.tailnetSuffix, peers: ["dash"])
        defer { app.terminate() }
        _ = try await waitForReport(host: "dash.tail-scale.ts.net", timeout: 30) {
            $0["ws"] as? String == "ws:open"
        }

        let link = app.webViews.links["Redirect away"]
        XCTAssertTrue(link.waitForExistence(timeout: 10), "the redirect link should render")
        link.tap()

        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 15),
                      "the other origin should open outside the app")
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        let errorPage = app.descendants(matching: .any).matching(identifier: "nav-error-overlay").firstMatch
        XCTAssertFalse(errorPage.waitForExistence(timeout: 3),
                       "a policy-cancelled redirect must not show the error page")
        let paths = try await dashboardState()["paths"] as? [String] ?? []
        XCTAssertTrue(paths.contains { $0.contains("/redirect-away") }, "the redirect was actually served")
        // Safari may well fetch /away-target — the harness origin resolves to
        // loopback, so it can. What must never happen is the APP's web view
        // fetching it. Mobile Safari's User-Agent carries a "Safari/" token; a
        // WKWebView's does not.
        let inApp = paths.filter { $0.contains("/away-target") && !$0.contains("Safari/") }
        XCTAssertTrue(inApp.isEmpty, "the other origin must never load in the app; saw \(inApp)")
    }

    // MARK: - R2: the sign-in token leaves the address

    /// The page navigates to /?token=… the way the dashboard's own paste
    /// banner does. The server receives the token — that is how sign-in works
    /// — but by the time the page's scripts run it is gone from the address.
    func testSignInTokenIsStrippedFromTheAddress() async throws {
        // -UITestLogResponses makes the app log every navigation's URL, so the
        // sign-in URL genuinely passes through the logger. That is what lets
        // scripts/test-offline.sh's R1 grep prove redaction rather than pass
        // vacuously: it requires the REDACTED form to be in the log.
        let app = launch(gateway: Self.gateway, suffix: Self.tailnetSuffix, peers: ["dash"],
                         extra: ["-UITestLogResponses"])
        defer { app.terminate() }
        _ = try await waitForReport(host: "dash.tail-scale.ts.net", timeout: 30) {
            $0["ws"] as? String == "ws:open"
        }

        let signIn = app.webViews.buttons["Sign in with token"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 10), "the sign-in button should render")
        signIn.tap()

        // Wait for a report from the NEW document: it carries a fresh ts and
        // the server has seen the token request.
        var sawTokenRequest = false
        for _ in 0..<40 {
            let paths = try await dashboardState()["paths"] as? [String] ?? []
            if paths.contains(where: { $0.contains("?token=OFFLINE-TEST-TOKEN-7f3a") }) {
                sawTokenRequest = true
                break
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        XCTAssertTrue(sawTokenRequest, "the server must receive the token (that is the sign-in)")

        let report = try await waitForReport(host: "dash.tail-scale.ts.net", timeout: 15) {
            $0["ws"] as? String == "ws:open"
        }
        XCTAssertEqual(report["search"] as? String, "",
                       "the token must be gone from the address before the page's scripts run")
    }

    // MARK: - Launch

    private func launch(gateway: String, suffix: String, peers: [String],
                        extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-UITestResetWorkspaces",
            "-UITestHomePage", gateway,
            "-TestStatusFixture", Self.fixture(suffix: suffix, peers: peers),
            "-TestProxyEndpoint", Self.proxyEndpoint,
            "-TestProxyCredential", Self.proxyCredential,
        ] + extra
        app.launch()
        return app
    }

    /// A minimal `IpnState.Status`: the fixture node, a MagicDNS suffix and
    /// the given peers. The 100.127.255.x addresses are never dialled — WebKit
    /// reaches every peer by name through the proxy — and sit at the far end
    /// of the CGNAT range, away from any real assignment.
    static func fixture(suffix: String, peers: [String]) -> String {
        func node(_ name: String, _ octet: Int) -> [String: Any] {
            ["ID": "fixture-\(name)", "HostName": name, "DNSName": "\(name).\(suffix).",
             "TailscaleIPs": ["100.127.255.\(octet)"], "Online": true,
             "ExitNode": false, "ExitNodeOption": false]
        }
        var peerMap: [String: Any] = [:]
        for (i, p) in peers.enumerated() { peerMap["nodekey:fixture-\(p)"] = node(p, 10 + i) }
        let status: [String: Any] = [
            "Version": "fixture", "BackendState": "Running", "AuthURL": "",
            "TailscaleIPs": ["100.127.255.1"],
            "Self": node("latchkey-iphone", 1),
            "CurrentTailnet": ["Name": suffix, "MagicDNSSuffix": suffix, "MagicDNSEnabled": true],
            "Peer": peerMap,
        ]
        let data = try! JSONSerialization.data(withJSONObject: status, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }

    // MARK: - Assertions

    private func assertErrorPage(_ app: XCUIApplication, _ message: String,
                                 file: StaticString = #filePath, line: UInt = #line) throws {
        let errorPage = app.descendants(matching: .any).matching(identifier: "nav-error-overlay").firstMatch
        XCTAssertTrue(errorPage.waitForExistence(timeout: 40), message, file: file, line: line)
    }

    private func assertZeroRequests(host: String,
                                    file: StaticString = #filePath, line: UInt = #line) async throws {
        let requests = try await dashboardState()["requests"] as? [String: Int] ?? [:]
        XCTAssertEqual(requests[host] ?? 0, 0,
                       "the dashboard must receive ZERO requests for \(host) — anything else is a direct leak. Saw \(requests)",
                       file: file, line: line)
    }

    /// The page's latest SSE tick number, or nil before the first one.
    private static func sseTick(_ report: [String: Any]) -> Int? {
        guard let s = report["sse"] as? String, s.hasPrefix("sse:tick-") else { return nil }
        return Int(s.dropFirst("sse:tick-".count))
    }

    // MARK: - Control-plane reads (R13)

    private func dashboardState() async throws -> [String: Any] {
        let data = try await Self.get("\(Self.dashboardControl)/__state")
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func waitForReport(host: String, timeout: TimeInterval,
                               until predicate: ([String: Any]) -> Bool) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        var last: [String: Any] = [:]
        while Date() < deadline {
            let reports = try await dashboardState()["reports"] as? [String: [String: Any]] ?? [:]
            if let r = reports[host] {
                last = r
                if predicate(r) { return r }
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        XCTFail("no matching report from \(host) within \(Int(timeout))s; last: \(last)")
        return last
    }

    private struct Connect: CustomStringConvertible {
        let host: String
        let port: Int
        var description: String { "\(host):\(port)" }
    }

    private func journalConnects() async throws -> [Connect] {
        let data = try await Self.get("\(Self.proxyControl)/journal")
        let events = (try JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
        return events.compactMap { e in
            guard e["event"] as? String == "connect",
                  let h = e["host"] as? String, let p = e["port"] as? Int else { return nil }
            return Connect(host: h, port: p)
        }
    }

    private static func get(_ url: String) async throws -> Data {
        var request = URLRequest(url: URL(string: url)!, timeoutInterval: 5)
        request.httpMethod = "GET"
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    @discardableResult
    private static func post(_ url: String) async throws -> Data {
        var request = URLRequest(url: URL(string: url)!, timeoutInterval: 5)
        request.httpMethod = "POST"
        let (data, _) = try await URLSession.shared.data(for: request)
        return data
    }
}
