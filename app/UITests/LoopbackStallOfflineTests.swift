// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

//
//  LoopbackStallOfflineTests.swift
//  LatchkeyUITests
//
//  L1 for F16 (docs/features/F16-loopback-stalls.md §6.4): the logging
//  relay starts without blocking the main actor, and the first load still
//  waits for the proxy it publishes.
//
//  The harness is OfflineHarnessTests' (the stub SOCKS5 proxy and the fake
//  dashboard, R11/R13), and so are its endpoints and fixture; the tests live
//  in their own class only so that file can change independently. Run by
//  `scripts/test-offline.sh`, which runs both classes.
//
//  `-UITestRelayReadyDelay <s>` holds the process's first relay listener
//  short of `.ready` for s seconds: the listener slow to start that F16 §1.4
//  describes. Before F16 the main actor waited on it; now `Running` is on the
//  model for those seconds with no proxy published, which is the window the
//  R10 anti-leak tests below are re-run in.
//

import XCTest

@MainActor
final class LoopbackStallOfflineTests: XCTestCase {

    typealias Offline = OfflineHarnessTests

    /// Under the relay's `startTimeout` (3 s), so the start still succeeds.
    static let relayDelay = "2"

    override func setUp() async throws {
        continueAfterFailure = false
        guard (try? await HarnessControl.get("\(Offline.dashboardControl)/__state")) != nil,
              (try? await HarnessControl.get("\(Offline.proxyControl)/journal")) != nil
        else {
            XCTFail("Offline harness is not running. Use scripts/test-offline.sh (parent repo).")
            return
        }
        try await HarnessInstance.assertIsOurs("\(Offline.dashboardControl)/__state")
        try await HarnessInstance.assertIsOurs("\(Offline.proxyControl)/state")
        for path in ["\(Offline.dashboardControl)/__reset", "\(Offline.proxyControl)/reset",
                     "\(Offline.proxyControl)/mode?blackhole=0", "\(Offline.proxyControl)/mode?stall=0",
                     "\(Offline.proxyControl)/open", "\(Offline.dashboardControl)/__mode?front=0&root=page"] {
            _ = try await HarnessControl.post(path)
        }
    }

    // MARK: - F16 stage 3: the relay starts without blocking

    /// The relay's listener takes 2.8 s to become ready. The app is
    /// responsive while it waits: no main-queue block posted in the start's
    /// last second (from 1.8 s in, past the launch's own main-thread work;
    /// `MainThreadStallProbe`) ran more than 250 ms late, where a start that
    /// waited on the listener made it about the whole second. And the
    /// dashboard still loads THROUGH the relay: the async start published the
    /// relay's port, not the upstream's (`relay-requests` counts the SOCKS
    /// requests the relay parsed; the stub's journal cannot tell the two
    /// paths apart).
    func testASlowRelayListenerDoesNotFreezeTheApp() async throws {
        let app = launch(gateway: Offline.gateway, suffix: Offline.tailnetSuffix,
                         extra: ["-UITestMainThreadMonitor", "1.8", "-UITestRelayReadyDelay", "2.8"])
        defer { app.terminate() }

        _ = try await waitForReport(host: "dash.\(Offline.tailnetSuffix)", timeout: 40) {
            $0["title"] as? String == "FAKE DASHBOARD"
        }
        let stall = Int(probe(app, "main-thread-max-stall-ms")) ?? -1
        let relayed = Int(probe(app, "relay-requests")) ?? -1
        print("OFFLINE F16 slow relay start: main thread max stall \(stall) ms, relay requests \(relayed)")
        XCTAssertGreaterThanOrEqual(stall, 0, "the main-thread monitor reports")
        XCTAssertLessThan(stall, 250, "no main-thread gap over 250 ms while the relay starts; saw \(stall) ms")
        XCTAssertGreaterThanOrEqual(relayed, 1, "the dashboard loaded through the relay, not around it")
        let connects = try await journalConnects()
        XCTAssertTrue(connects.contains("dash.\(Offline.tailnetSuffix):443"),
                      "the stub proxy journals the CONNECT; got \(connects)")
    }

    /// R10 step 2 (`OfflineHarnessTests.testBlackholedProxyFailsWithoutDirectFallback`)
    /// with the proxy published 2 s after `Running`: the leak origin is the
    /// tailnet, the proxy refuses every CONNECT, and the dashboard receives
    /// ZERO requests. A first load made before the proxy was in the store
    /// would have gone direct, and succeeded.
    func testABlackholedProxyBehindASlowRelayStartFailsWithoutDirectFallback() async throws {
        _ = try await HarnessControl.post("\(Offline.proxyControl)/mode?blackhole=1")
        let app = launch(gateway: Offline.leakOrigin, suffix: "localtest.me",
                         extra: ["-UITestRelayReadyDelay", Self.relayDelay])
        defer { app.terminate() }

        XCTAssertTrue(element(app, "nav-error-overlay").appears(within: 40),
                      "a blackholed proxy must fail the load")
        let connects = try await journalConnects()
        XCTAssertTrue(connects.contains { $0.hasPrefix("dash.localtest.me:") },
                      "the attempt must have reached the proxy; got \(connects)")
        try await assertZeroRequests(host: "dash.localtest.me")
    }

    /// R10 variant (`OfflineHarnessTests.testProxyGoneFailsWithoutDirectFallback`)
    /// with the same late proxy: the stub is gone, the relay in front of it
    /// starts slowly, and nothing reaches the dashboard directly.
    func testAGoneProxyBehindASlowRelayStartFailsWithoutDirectFallback() async throws {
        _ = try await HarnessControl.post("\(Offline.proxyControl)/close")
        let app = launch(gateway: Offline.leakOrigin, suffix: "localtest.me",
                         extra: ["-UITestRelayReadyDelay", Self.relayDelay])
        defer { app.terminate() }

        XCTAssertTrue(element(app, "nav-error-overlay").appears(within: 40),
                      "an unreachable proxy must fail the load")
        try await assertZeroRequests(host: "dash.localtest.me")
    }

    // MARK: - Helpers

    private func launch(gateway: String, suffix: String, extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-UITestResetWorkspaces",
            "-UITestHomePage", gateway,
            "-TestStatusFixture", Offline.fixture(suffix: suffix, peers: ["dash"]),
            "-TestProxyEndpoint", Offline.proxyEndpoint,
            "-TestProxyCredential", Offline.proxyCredential,
        ] + extra
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// A probe's live value (`MainThreadStallProbe`), or "" if it is absent.
    private func probe(_ app: XCUIApplication, _ id: String) -> String {
        let e = element(app, id)
        guard e.appears(within: 5) else { return "" }
        return e.value as? String ?? ""
    }

    private func dashboardState() async throws -> [String: Any] {
        let data = try await HarnessControl.get("\(Offline.dashboardControl)/__state")
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
        XCTFail("no matching report from \(host) within \(Int(timeout)) s; last: \(last)")
        return last
    }

    private func assertZeroRequests(host: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        let requests = try await dashboardState()["requests"] as? [String: Int] ?? [:]
        XCTAssertEqual(requests[host] ?? 0, 0,
                       "the dashboard must receive ZERO requests for \(host); anything else is a direct leak. Saw \(requests)",
                       file: file, line: line)
    }

    /// The stub proxy's CONNECTs, as `host:port`.
    private func journalConnects() async throws -> [String] {
        let data = try await HarnessControl.get("\(Offline.proxyControl)/journal")
        let events = (try JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
        return events.compactMap { e in
            guard e["event"] as? String == "connect", let h = e["host"] as? String,
                  let p = e["port"] as? Int else { return nil }
            return "\(h):\(p)"
        }
    }
}
