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
//  Endpoints are testing/harness/Makefile's, for the instance the script
//  names (HarnessInstance; instance 0 unless told otherwise).
//
//  Never use a real tailnet name or address here (R10): on a machine running
//  Tailscale, a leak to one would SUCCEED through the host's VPN.
//

import UIKit
import XCTest

@MainActor
final class OfflineHarnessTests: XCTestCase {

    // MARK: - Harness endpoints (testing/harness/Makefile)

    static let proxyEndpoint = "127.0.0.1:\(HarnessInstance.port("PROXY_PORT", default: 1080))"
    static let proxyCredential = "s3cret"
    static let dashboardControl = "http://127.0.0.1:\(HarnessInstance.port("DASH_CONTROL_PORT", default: 8480))"
    static let proxyControl = "http://127.0.0.1:\(HarnessInstance.port("PROXY_CONTROL_PORT", default: 1081))"

    /// The fixture tailnet. Public DNS answers NXDOMAIN for it, so its names
    /// can only ever load through the proxy.
    static let tailnetSuffix = "tail-scale.ts.net"
    static let gateway = "https://dash.tail-scale.ts.net"
    /// A PUBLIC name resolving to 127.0.0.1 and ::1, served by the same fake
    /// dashboard. The anti-leak origin (R10): a leaked direct connection to it
    /// would succeed, so a leak is detectable.
    static let leakOrigin = "https://dash.localtest.me:\(HarnessInstance.port("DASH_PORT", default: 8443))"

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
        try await HarnessInstance.assertIsOurs("\(Self.dashboardControl)/__state")
        try await HarnessInstance.assertIsOurs("\(Self.proxyControl)/state")
        _ = try await Self.post("\(Self.dashboardControl)/__reset")
        _ = try await Self.post("\(Self.proxyControl)/reset")
        _ = try await Self.post("\(Self.proxyControl)/mode?blackhole=0")
        _ = try await Self.post("\(Self.proxyControl)/mode?stall=0")
        _ = try await Self.post("\(Self.proxyControl)/open")
        _ = try await Self.post("\(Self.dashboardControl)/__mode?front=0&root=page")
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
        assertConnectionFailure(app, "an unreachable proxy behind the relay (measured: -1009)")
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
        assertConnectionFailure(app, "an unreachable proxy dialled by WebKit itself (measured: -1004)")
        try await assertZeroRequests(host: "dash.localtest.me")
    }

    // MARK: - A 5xx on a live connection (F4 D10)

    /// A gateway that answers **502 on a healthy port** must show the error
    /// page, not commit an empty body as the document.
    ///
    /// This is the shape production actually produces and no other test here
    /// covers: `tailscale serve`'s reverse proxy has no error handler, so a
    /// stopped Kiro Crew answers 502 while TLS completes normally. Every other
    /// failure mode in this harness — close, reset, blackhole — raises an
    /// `NSURLError` the app can see. This one raises nothing at all, which is
    /// why the blank screen went unnoticed: before F4 D10 the delegate allowed
    /// every response without looking at its status.
    func testAGatewayAnswering502ShowsTheErrorPageInsteadOfABlankScreen() async throws {
        // Registered BEFORE the mode is set, and as a teardown block rather
        // than a `defer` with a detached Task: the restore must be awaited, or
        // a failure here leaves the harness answering 502 and every later test
        // in this file fails for the wrong reason.
        addTeardownBlock {
            try? await Self.post("\(Self.dashboardControl)/__mode?front=0")
        }
        try await Self.post("\(Self.dashboardControl)/__mode?front=502")
        let app = launch(gateway: Self.gateway, suffix: Self.tailnetSuffix, peers: ["dash"])
        defer { app.terminate() }
        try assertErrorPage(app, "a 502 on a live port must not commit as the page")
        // Pin the cause. Without this the test would pass on any failure —
        // including the transport failures the other modes produce, which are
        // exactly what this test exists to distinguish itself from.
        // The words are F4 §4.4's now, not ResponsePolicy.refusalText's: the
        // rebuilt page owns its wording in one place (§3.2).
        let stopped = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] %@", "restarting or stopped")).firstMatch
        XCTAssertTrue(stopped.appears(within: 5),
                      "the page should say Kiro Crew is not running behind the gateway")
        let reassurance = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] %@", "but Kiro Crew behind it didn't")).firstMatch
        XCTAssertTrue(reassurance.exists,
                      "and should blame what is behind the gateway, not the tailnet, so the owner does not debug grants")
        // The connection really was made and really was answered: this is not
        // a dial that failed.
        let connects = try await journalConnects()
        XCTAssertTrue(connects.contains { $0.host == "dash.tail-scale.ts.net" && $0.port == 443 },
                      "the load must have reached the server through the proxy; got \(connects)")
    }

    // MARK: - F4: the connecting state, and an error page you can act on

    /// The headline of F4. A load that will never answer shows a connecting
    /// state for its WHOLE duration, and then a failure that names the cause.
    ///
    /// `stall=22` is chosen, not arbitrary: it is longer than the app's 20 s
    /// silent-retry window, so the failure arrives after that window closes and
    /// exactly ONE dial happens — which is the path the device took in the
    /// report that produced this feature (F4 §1.1). The stall also makes the
    /// state last long enough to assert anything about it at all: every other
    /// failure mode this harness has fails at once, and a state present for
    /// 300 ms is caught by luck or missed.
    func testStalledLoadShowsTheConnectingStateForItsWholeDuration() async throws {
        // The checkpoints are a picture of one load over 20 s; stopping at the
        // first bad one would hide the rest of it.
        continueAfterFailure = true
        addTeardownBlock { try? await Self.post("\(Self.proxyControl)/mode?stall=0") }
        try await Self.post("\(Self.proxyControl)/mode?stall=22")
        let app = launch(gateway: Self.gateway, suffix: Self.tailnetSuffix, peers: ["dash"])
        defer { app.terminate() }
        let launchedAt = Date()

        // Absolute checkpoints from the launch, not waitForExistence: a wait on
        // a transient passes even when the state is stuck, which is the bug.
        var lastElapsed = -1
        for checkpoint in [1.0, 4.0, 7.0, 11.0, 20.0] {
            try await sleep(until: launchedAt.addingTimeInterval(checkpoint))
            // Every read is guarded: a missing element makes `.label`/`.value`
            // THROW, which aborts the test before the later checkpoints and
            // before the teardown that restores the stall. Asserting instead
            // keeps the whole picture and the cleanup.
            let block = element(app, "page-connecting")
            XCTAssertTrue(block.exists,
                          "at \(Int(checkpoint)) s the connecting state must be on screen")
            let host = element(app, "page-connecting-host")
            XCTAssertTrue(host.exists && host.label.contains("dash"),
                          "at \(Int(checkpoint)) s it names the host: \(host.exists ? host.label : "<absent>")")
            // The ticking number: its label is static so VoiceOver does not
            // announce every second, which puts the seconds in the VALUE.
            let elapsed = element(app, "page-connecting-elapsed")
            if elapsed.exists {
                let text = (elapsed.value as? String ?? "").replacingOccurrences(of: " s", with: "")
                let shown = Int(text.trimmingCharacters(in: .whitespaces)) ?? -1
                XCTAssertGreaterThanOrEqual(shown, lastElapsed,
                                            "the elapsed number must never go backwards (was \(lastElapsed), now \(shown))")
                lastElapsed = max(lastElapsed, shown)
            } else {
                XCTFail("at \(Int(checkpoint)) s the elapsed number must be on screen")
            }
            // The hint is the escalation, and it must not arrive early.
            let hint = element(app, "page-connecting-hint")
            if checkpoint <= 4.0 {
                XCTAssertFalse(hint.exists, "at \(Int(checkpoint)) s it is too early to nag")
            } else if checkpoint >= 11.0 {
                XCTAssertTrue(hint.exists, "by \(Int(checkpoint)) s it says what is probably wrong")
                XCTAssertTrue(element(app, "page-connecting-choose-gateway").exists,
                              "and offers a way out")
            }
        }

        // The failure, when it comes, names the host, the port and the duration.
        let overlay = element(app, "nav-error-overlay")
        XCTAssertTrue(overlay.appears(within: 20), "the stalled dial must end on the error page")
        let cause = element(app, "nav-error-cause").label
        XCTAssertTrue(cause.contains("didn't answer on port 443"),
                      "the cause names what happened: \(cause)")
        // How long it waited, read from the sentence rather than predicted.
        // Measured: ~31 s for a 22 s stall, because WebKit dials more than once
        // within one navigation (see the CONNECT count below). What matters to
        // the owner, and here, is that the number is the real wait and not zero.
        let waited = cause.components(separatedBy: " in ").last
            .flatMap { $0.components(separatedBy: " s").first }
            .flatMap { Int($0) } ?? -1
        XCTAssertGreaterThanOrEqual(waited, 20,
                                    "the cause names the real duration of the wait: \(cause)")
        XCTAssertFalse(cause.lowercased().contains("url"),
                       "and never calls a connection failure a URL problem: \(cause)")
        XCTAssertTrue(element(app, "nav-error-retry").exists, "with something to do about it")

        // No retry STORM: the failure arrived after the app's 20 s startup-retry
        // window closed, so `retryStartupLoadIfAppropriate` never ran. That loop
        // dials once a second, so had it run there would be upwards of twenty
        // CONNECTs here.
        //
        // Not "exactly one", which F4 §6 asked for and which is wrong: WebKit
        // issues more than one dial within a single navigation (measured: 2 for
        // one stalled load, and the whole navigation then fails at ~31 s rather
        // than at the 22 s stall). The app's own retry loop is what this pins.
        let connects = try await journalConnects()
        let toDash = connects.filter { $0.host == "dash.\(Self.tailnetSuffix)" && $0.port == 443 }
        XCTAssertGreaterThanOrEqual(toDash.count, 1, "the load must have dialled: \(connects)")
        XCTAssertLessThanOrEqual(toDash.count, 3,
                                 "the silent retry loop must NOT have run past its window: \(connects)")
    }

    /// A healthy load must not leave the connecting block on screen — and must
    /// not flash it either, which a poll cannot see but the counter can.
    func testAFastLoadDoesNotLeaveTheConnectingStateOnScreen() async throws {
        let app = launch(gateway: Self.gateway, suffix: Self.tailnetSuffix, peers: ["dash"])
        defer { app.terminate() }
        // Server-side proof the page is up, rather than a sleep.
        _ = try await waitForReport(host: "dash.\(Self.tailnetSuffix)", timeout: 40) { _ in true }
        XCTAssertFalse(element(app, "page-connecting").exists,
                       "the block must be gone the instant the page commits")
        XCTAssertFalse(element(app, "nav-error-overlay").exists, "and no error page")
        let shown = element(app, "page-connecting-shown-count").label
        XCTAssertTrue(shown == "connecting-shown:0" || shown == "connecting-shown:1",
                      "a loopback load is under the 300 ms show delay, so it appears at most once: \(shown)")
    }

    /// Both buttons on the error page work. They are the reason the block is
    /// opaque: a control drawn at less than full opacity over a WKWebView
    /// receives no taps (found in M8), so a test that only asserts they EXIST
    /// would pass with them dead.
    func testTheErrorPageOffersRetryAndAnotherGateway() async throws {
        addTeardownBlock { try? await Self.post("\(Self.proxyControl)/mode?blackhole=0") }
        try await Self.post("\(Self.proxyControl)/mode?blackhole=1")
        let app = launch(gateway: Self.gateway, suffix: Self.tailnetSuffix, peers: ["dash"])
        XCTAssertTrue(element(app, "nav-error-overlay").appears(within: 40),
                      "a refused connection fails onto the error page")

        // Try again, with the proxy working: the load must really be retried,
        // proven by the gateway reporting itself.
        try await Self.post("\(Self.proxyControl)/mode?blackhole=0")
        let retry = element(app, "nav-error-retry")
        XCTAssertTrue(retry.isHittable, "Try again must be tappable, not merely present")
        retry.tap()
        _ = try await waitForReport(host: "dash.\(Self.tailnetSuffix)", timeout: 40) { _ in true }
        XCTAssertFalse(element(app, "nav-error-overlay").exists, "and the page replaces the error")
        app.terminate()

        // Choose another gateway opens the picker.
        try await Self.post("\(Self.proxyControl)/mode?blackhole=1")
        let again = launch(gateway: Self.gateway, suffix: Self.tailnetSuffix, peers: ["dash"])
        defer { again.terminate() }
        XCTAssertTrue(element(again, "nav-error-overlay").appears(within: 40))
        let choose = element(again, "nav-error-choose-gateway")
        XCTAssertTrue(choose.isHittable, "Choose another gateway must be tappable")
        choose.tap()
        XCTAssertTrue(element(again, "gateway-picker").appears(within: 10),
                      "and open the one picker presentation")
    }

    // MARK: - The error page (coverage lost with the address bar in M1)

    /// A certificate that does not name the host fails the load onto the
    /// app's error page, instead of loading or hanging.
    func testCertificateNameMismatchShowsTheErrorPage() async throws {
        let app = launch(gateway: "https://wrong.tail-scale.ts.net", suffix: Self.tailnetSuffix,
                         peers: ["dash", "wrong"])
        defer { app.terminate() }
        try assertErrorPage(app, "a certificate for the wrong name must not load")
        // Pin the cause, so an unrelated failure (a dropped --map, a proxy
        // left blackholed) cannot pass for this one (M2 review): the request
        // went through the proxy to the mapped server, and the error is about
        // the certificate.
        let connects = try await journalConnects()
        XCTAssertTrue(connects.contains { $0.host == "wrong.tail-scale.ts.net" && $0.port == 443 },
                      "the load must have reached the server through the proxy; got \(connects)")
        let certificateText = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] %@", "certificate")).firstMatch
        XCTAssertTrue(certificateText.appears(within: 5),
                      "the error page should say the certificate is the problem")
    }

    /// A gateway that refuses connections shows the error page.
    func testUnreachableGatewayShowsTheErrorPage() async throws {
        let app = launch(gateway: "https://down.tail-scale.ts.net", suffix: Self.tailnetSuffix,
                         peers: ["dash", "down"])
        defer { app.terminate() }
        try assertErrorPage(app, "a refused connection must show the error page")
        // Pin the cause (M2 review): the proxy tried the mapped, closed port.
        let data = try await Self.get("\(Self.proxyControl)/journal")
        let events = (try JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
        XCTAssertTrue(events.contains { $0["event"] as? String == "upstream_fail" },
                      "the proxy should have failed to reach the gateway's closed port; got \(events)")
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
        XCTAssertTrue(link.appears(within: 10), "the redirect link should render")
        link.tap()

        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 15),
                      "the other origin should open outside the app")
        // Close it again: a Safari tab left on a harness origin could keep
        // talking to the fake dashboard during later tests (M2 review).
        safari.terminate()
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

    // MARK: - F6: the page loads the gateway, four named CDNs, and nothing else

    /// The away origin's host, as the dashboard counts it (no port).
    static let awayHost = "dash.localtest.me"
    /// Lookalikes of the allowlisted esm.sh (F6 §4.1a(2)): each is mapped to
    /// the fake by the stub, so it WOULD be served and counted if allowed.
    static let cdnLookalikes = ["esm.sh.away.example", "esm.shady.example"]
    static let fontHosts = ["fonts.googleapis.com", "fonts.gstatic.com"]

    /// Launches the app on F6's page (`dashboard.py`'s SINGLE, at /).
    /// `-ProxyEverything` always: in L1 a non-tailnet host loads direct, and
    /// the page names esm.sh and Google's font hosts. Proxied, every one of
    /// them reaches the stub, which maps it to the fake on loopback — so no
    /// run of this page can reach the real internet, and the journal sees
    /// every connection, preconnects included.
    private func launchSingleOrigin(extra: [String] = []) async throws -> XCUIApplication {
        try await Self.post("\(Self.dashboardControl)/__mode?root=single")
        return launch(gateway: Self.gateway, suffix: Self.tailnetSuffix, peers: ["dash"],
                      extra: ["-ProxyEverything"] + extra)
    }

    /// The F6 page's report once everything it does at load has been done:
    /// its WebSocket open, the runtime widening attempt made (2 s) and the
    /// synthetic click tried (4 s). Every off-origin load it makes has been
    /// asked for by then. `notDoc` skips a report from a document replaced.
    private func waitForSingleOriginSettled(notDoc: String? = nil,
                                            timeout: TimeInterval = 40) async throws -> [String: Any] {
        let report = try await waitForReport(host: "dash.tail-scale.ts.net", timeout: timeout) {
            Self.isSettled($0) && (notDoc == nil || $0["doc"] as? String != notDoc)
        }
        // The last of them (the widening fetches) had a second to fail or land.
        try await Task.sleep(for: .seconds(1))
        return report
    }

    private static func isSettled(_ report: [String: Any]) -> Bool {
        report["page"] as? String == "single" && report["ws"] as? String == "ws:open"
            && report["widened"] as? String == "done"
            && (report["synthetic_click"] as? String)?.hasPrefix("done") == true
    }

    /// Everything the harness saw of one settled run of the F6 page: the
    /// page's report, the fake's counters and the proxy's journal, read
    /// together once the page has settled.
    private struct SingleOriginRun {
        let report: [String: Any]
        let state: [String: Any]
        let connects: [Connect]
        var requests: [String: Int] { state["requests"] as? [String: Int] ?? [:] }
        var handshakes: [String: Int] { state["handshakes"] as? [String: Int] ?? [:] }
        var paths: [String] { state["paths"] as? [String] ?? [] }
        /// `paths` lines for `host` that did not come from Mobile Safari.
        func inAppPaths(host: String) -> [String] {
            paths.filter { $0.hasPrefix(host + " ") && !$0.contains("Safari/") }
        }
    }

    private func observe(_ report: [String: Any]) async throws -> SingleOriginRun {
        SingleOriginRun(report: report, state: try await dashboardState(), connects: try await journalConnects())
    }

    private static var defaultRun: SingleOriginRun?

    /// The default F6 run (rule list on, CDNs allowed), taken by the first
    /// test that needs it and read by the four that only observe it (F14):
    /// they each launched the same way, waited for the same settle and then
    /// only read the instruments, so one launch serves them all, and each
    /// still asserts its own claim under its own name. Not cached unless it
    /// settled, so a failed launch fails only the test that took it, and a
    /// test run on its own takes its own.
    private func settledDefaultRun() async throws -> SingleOriginRun {
        if let run = Self.defaultRun { return run }
        let app = try await launchSingleOrigin()
        defer { app.terminate() }
        let run = try await observe(try await waitForSingleOriginSettled())
        if Self.isSettled(run.report) { Self.defaultRun = run }
        return run
    }

    private func handshakes() async throws -> [String: Int] {
        try await dashboardState()["handshakes"] as? [String: Int] ?? [:]
    }

    private func requestCounts() async throws -> [String: Int] {
        try await dashboardState()["requests"] as? [String: Int] ?? [:]
    }

    /// `paths` lines for `host` that did not come from Mobile Safari (whose
    /// User-Agent carries a `Safari/` token; a WKWebView's does not).
    private func inAppPaths(host: String) async throws -> [String] {
        let paths = try await dashboardState()["paths"] as? [String] ?? []
        return paths.filter { $0.hasPrefix(host + " ") && !$0.contains("Safari/") }
    }

    /// Every single-origin assertion, shared by the strict-mode test: zero
    /// requests, zero CONNECTs and zero TLS handshakes for the away origin,
    /// and nothing for the gateway's host on another port.
    private func assertNothingReachedTheAwayOrigin(_ context: String, in run: SingleOriginRun,
                                                   file: StaticString = #filePath, line: UInt = #line) {
        let requests = run.requests
        XCTAssertEqual(requests[Self.awayHost] ?? 0, 0,
                       "\(context): the away origin must receive ZERO requests; saw \(requests)", file: file, line: line)
        let leaked = run.inAppPaths(host: Self.awayHost)
        XCTAssertTrue(leaked.isEmpty, "\(context): no /f6/ path from the app; saw \(leaked)", file: file, line: line)
        let connects = run.connects
        XCTAssertFalse(connects.contains { $0.host == Self.awayHost },
                       "\(context): no CONNECT to the away origin; got \(connects)", file: file, line: line)
        XCTAssertFalse(connects.contains { $0.host == "dash.tail-scale.ts.net" && $0.port == 8444 },
                       "\(context): the gateway's host on another port is another origin; got \(connects)",
                       file: file, line: line)
        let tls = run.handshakes
        XCTAssertEqual(tls[Self.awayHost] ?? 0, 0,
                       "\(context): no TLS handshake with the away origin, so no preconnect either; saw \(tls)",
                       file: file, line: line)
    }

    /// F6 §6, the negative. A page referencing the away origin a dozen ways —
    /// img, alt="" img, an img in a same-origin frame, script, stylesheet,
    /// preload, preconnect, iframe, video, ping, fetch, EventSource,
    /// WebSocket, sendBeacon, a Worker's and a SharedWorker's fetch, a
    /// same-origin image that redirects away — and the gateway's host on port
    /// 8444. Three instruments, each at zero: the fake's per-Host count, the
    /// proxy's CONNECT journal, and the fake's TLS handshakes by SNI, the only
    /// one that can see a preconnect.
    func testOffOriginLoadsNeverReachTheAwayOrigin() async throws {
        assertNothingReachedTheAwayOrigin("with the rule list", in: try await settledDefaultRun())
    }

    /// F6 §6, the positive control (R10's shape): the same page without the
    /// rule list reaches the away origin by every instrument, so the zeros
    /// above mean something. It also shows the lookalike CDN hosts and the
    /// font hosts would be served and counted, which the tests below need
    /// for their own zeros.
    func testWithoutTheRuleListTheAwayOriginIsReached() async throws {
        let app = try await launchSingleOrigin(extra: ["-UITestNoContentRules"])
        defer { app.terminate() }
        _ = try await waitForSingleOriginSettled()
        let requests = try await requestCounts()
        XCTAssertGreaterThan(requests[Self.awayHost] ?? 0, 0, "the away origin is reached; saw \(requests)")
        let paths = try await inAppPaths(host: Self.awayHost)
        for path in ["/f6/img.png", "/f6/fetch", "/f6/frame"] {
            XCTAssertTrue(paths.contains { $0.contains(" \(path) ") }, "\(path) was served in-app; saw \(paths)")
        }
        let connects = try await journalConnects()
        XCTAssertTrue(connects.contains { $0.host == Self.awayHost },
                      "the journal sees the away origin; got \(connects)")
        XCTAssertTrue(connects.contains { $0.host == "dash.tail-scale.ts.net" && $0.port == 8444 },
                      "the journal sees the port probe; got \(connects)")
        XCTAssertTrue(connects.contains { $0.host == "esm.sh" && $0.port == 8444 },
                      "and esm.sh on another port, or its zero in the allowlist test is vacuous; got \(connects)")
        let cdnPort = try await inAppPaths(host: "esm.sh").filter { $0.contains("/f6/cdn-port") }
        XCTAssertFalse(cdnPort.isEmpty, "esm.sh:8444 would be served if allowed")
        let tls = try await handshakes()
        XCTAssertGreaterThanOrEqual(tls[Self.awayHost] ?? 0, 1,
                                    "the handshake counter sees the away origin, or its zero above is vacuous; saw \(tls)")
        for host in Self.cdnLookalikes + Self.fontHosts {
            XCTAssertGreaterThan(requests[host] ?? 0, 0,
                                 "\(host) would be served if allowed, or its zero below is vacuous; saw \(requests)")
        }
    }

    /// F6 §4.1a: the allowlisted esm.sh is fetched and its script runs, and
    /// in the SAME run nothing adjacent to it is: not a longer host that
    /// starts with it, not a host sharing its prefix, not esm.sh on another
    /// port. One test, because the allowance and the anchoring must hold at
    /// once or the allowlist is not what it claims. (Counts are by Host
    /// without port, so the port is read from the paths and the journal.)
    func testAnAllowlistedCDNIsFetchedAndItsLookalikesAreNot() async throws {
        let run = try await settledDefaultRun()
        let report = run.report
        XCTAssertEqual(report["cdn"] as? String, "ok", "esm.sh's script ran: \(report)")
        let requests = run.requests
        XCTAssertGreaterThan(requests["esm.sh"] ?? 0, 0, "esm.sh was fetched; saw \(requests)")
        for host in Self.cdnLookalikes {
            XCTAssertEqual(requests[host] ?? 0, 0, "\(host) must not be fetched; saw \(requests)")
        }
        let cdnPort = run.inAppPaths(host: "esm.sh").filter { $0.contains("/f6/cdn-port") }
        XCTAssertTrue(cdnPort.isEmpty, "esm.sh on port 8444 must not be fetched; saw \(cdnPort)")
        let connects = run.connects
        XCTAssertFalse(connects.contains { $0.host == "esm.sh" && $0.port == 8444 },
                       "no CONNECT to esm.sh:8444; got \(connects)")
        XCTAssertFalse(connects.contains { Self.cdnLookalikes.contains($0.host) },
                       "no CONNECT to a lookalike; got \(connects)")
    }

    /// F6 §2: the font hosts stay blocked while the CDNs are allowed — by
    /// request count and by TLS handshake (the bundle's two preconnects are
    /// to exactly these), while esm.sh in the same run is fetched.
    func testTheFontHostsStayBlockedWhileTheCDNsAreAllowed() async throws {
        let run = try await settledDefaultRun()
        let requests = run.requests
        let tls = run.handshakes
        XCTAssertGreaterThan(requests["esm.sh"] ?? 0, 0, "the allowlist is on in this run; saw \(requests)")
        for host in Self.fontHosts {
            XCTAssertEqual(requests[host] ?? 0, 0, "\(host) must not be fetched; saw \(requests)")
            XCTAssertEqual(tls[host] ?? 0, 0, "\(host) must not even be handshaken with; saw \(tls)")
        }
    }

    /// F6 §6: a page cannot add to a compiled list. The page appends a
    /// script and a fetch for the away origin and for a lookalike at runtime,
    /// 2 s after load; neither reaches anything.
    func testThePageCannotWidenTheAllowlist() async throws {
        let run = try await settledDefaultRun()
        XCTAssertEqual(run.report["widened"] as? String, "done")
        for host in [Self.awayHost, "esm.sh.away.example"] {
            let hits = run.paths.filter { $0.hasPrefix(host + " ") && $0.contains("/f6/widen") }
            XCTAssertTrue(hits.isEmpty, "\(host): the page's runtime additions must not load; saw \(hits)")
        }
        let requests = run.requests
        XCTAssertEqual(requests[Self.awayHost] ?? 0, 0, "saw \(requests)")
        XCTAssertEqual(requests["esm.sh.away.example"] ?? 0, 0, "saw \(requests)")
    }

    /// F6 §4.1's rules 3–6 and the service-worker row of §4.2: under the list
    /// the gateway's own machinery works — its WebSocket, its SSE, a data:
    /// image, a blob: image, a blob: worker, a srcdoc frame — and a service
    /// worker cannot exist. The report arriving at all proves same-origin
    /// fetch.
    func testTheGatewaysOwnMachineryStillWorks() async throws {
        let app = try await launchSingleOrigin()
        defer { app.terminate() }
        let report = try await waitForReport(host: "dash.tail-scale.ts.net", timeout: 40) {
            $0["page"] as? String == "single" && $0["ws"] as? String == "ws:open"
                && ($0["sse"] as? String)?.hasPrefix("sse:tick-") == true
                && $0["data_img"] as? String == "ok" && $0["blob_img"] as? String == "ok"
                && $0["blob_worker"] as? String == "ok" && $0["srcdoc"] as? String == "ok"
        }
        XCTAssertEqual(report["sw"] as? String, "undefined", "no service workers without app-bound domains")
        XCTAssertEqual(report["sw_reg"] as? String, "unavailable")
        // Recorded, not asserted: a future bundle's use of either is noticed here.
        print("F6 capability probes: rtc=\(report["rtc"] ?? "?") wt=\(report["wt"] ?? "?")")
    }

    /// F6 §2: a filter that cannot be built loads nothing — WebKit's own
    /// compile failure (an unknown action), F4's error page naming the
    /// filter, zero requests and zero CONNECTs for the gateway, and Try
    /// again fails the same way rather than loading unprotected.
    func testFailedRuleCompileLoadsNothing() async throws {
        let app = launch(gateway: Self.gateway, suffix: Self.tailnetSuffix, peers: ["dash"],
                         extra: ["-UITestBreakContentRules"])
        defer { app.terminate() }
        XCTAssertTrue(element(app, "nav-error-overlay").appears(within: 10),
                      "a compile failure shows the error page")
        let filter = app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", "filter")).firstMatch
        XCTAssertTrue(filter.appears(within: 5), "the error page says the filter is why")
        try await Task.sleep(for: .seconds(2))
        try await assertZeroRequests(host: "dash.tail-scale.ts.net")
        var connects = try await journalConnects()
        XCTAssertFalse(connects.contains { $0.host == "dash.tail-scale.ts.net" },
                       "nothing may even dial the gateway; got \(connects)")

        let retry = element(app, "nav-error-retry")
        XCTAssertTrue(retry.isHittable, "Try again is offered")
        retry.tap()
        XCTAssertTrue(element(app, "nav-error-overlay").appears(within: 10), "and fails the same way")
        try await Task.sleep(for: .seconds(2))
        try await assertZeroRequests(host: "dash.tail-scale.ts.net")
        connects = try await journalConnects()
        XCTAssertFalse(connects.contains { $0.host == "dash.tail-scale.ts.net" },
                       "Try again must not load unprotected; got \(connects)")
    }

    /// F6 §4.1 rule 2: `window.open` is consulted as `popup` before the UI
    /// delegate is asked; blocked there, it returns null and nothing happens.
    /// Exempt, it reaches the navigation policy, which hands it to Safari.
    func testWindowOpenToAnotherOriginStillOpensSafari() async throws {
        let app = try await launchSingleOrigin()
        defer { app.terminate() }
        _ = try await waitForSingleOriginSettled()
        try await Self.post("\(Self.dashboardControl)/__reset")
        let link = app.webViews.links["Open away window"]
        XCTAssertTrue(link.appears(within: 10), "the window.open link renders")
        link.tap()
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 15), "window.open to another origin opens Safari")
        safari.terminate()
        app.activate()
        let inApp = try await inAppPaths(host: Self.awayHost).filter { $0.contains("/away-target") }
        XCTAssertTrue(inApp.isEmpty, "the other origin must never load in the app; saw \(inApp)")
    }

    /// F6 §4a: a blocked image gets a marker — the alt-less one, the alt=""
    /// one and the one in the same-origin frame — that VoiceOver reads and a
    /// finger can hit (44 pt). The page's own `el.click()` and its own post
    /// to the handler do nothing (the handler is not in its world); a real
    /// tap opens the image in Safari, which fetches it with Safari's UA.
    func testBlockedImageShowsAMarkerThatOpensSafari() async throws {
        let app = try await launchSingleOrigin()
        defer { app.terminate() }
        let report = try await waitForReport(host: "dash.tail-scale.ts.net", timeout: 40) {
            $0["page"] as? String == "single" && ($0["blocked_marks"] as? Int ?? 0) >= 3
                && ($0["blocked_marks_inner"] as? Int ?? 0) >= 1
                && ($0["synthetic_click"] as? String)?.hasPrefix("done") == true
        }
        XCTAssertGreaterThanOrEqual(report["blocked_marks"] as? Int ?? 0, 3,
                                    "no-alt, alt=\"\" and the inner frame's image are all marked: \(report)")
        XCTAssertGreaterThanOrEqual(report["blocked_marks_inner"] as? Int ?? 0, 1,
                                    "the image inside the same-origin frame is marked too: \(report)")
        XCTAssertEqual(report["synthetic_click"] as? String, "done", "the page did click a marker itself")
        XCTAssertEqual(report["page_handler"] as? String, "absent", "the app's handler is invisible to the page")

        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        // The page's synthetic click happened at 4 s; give it every chance.
        try await Task.sleep(for: .seconds(3))
        XCTAssertNotEqual(safari.state, .runningForeground, "a script's click must not open Safari")
        var paths = try await dashboardState()["paths"] as? [String] ?? []
        XCTAssertFalse(paths.contains { $0.contains("/f6/img.png") && $0.contains("Safari/") },
                       "nothing fetched the image in Safari yet")

        let marker = app.webViews.images.matching(
            NSPredicate(format: "label == %@", "Image not loaded. Tap to open in Safari.")).firstMatch
        XCTAssertTrue(marker.appears(within: 10), "VoiceOver reads the marker")
        XCTAssertGreaterThanOrEqual(marker.frame.width, 44, "a 44 pt target: \(marker.frame)")
        XCTAssertGreaterThanOrEqual(marker.frame.height, 44, "a 44 pt target: \(marker.frame)")
        marker.tap()
        XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 15), "a real tap opens Safari")
        let deadline = Date().addingTimeInterval(15)
        var opened = false
        while Date() < deadline, !opened {
            paths = try await dashboardState()["paths"] as? [String] ?? []
            opened = paths.contains { $0.hasPrefix(Self.awayHost + " ") && $0.contains("/f6/img") && $0.contains("Safari/") }
            if !opened { try await Task.sleep(for: .milliseconds(500)) }
        }
        safari.terminate()
        app.activate()
        XCTAssertTrue(opened, "Safari fetched the blocked image; paths: \(paths.filter { $0.contains("/f6/img") })")
        let inApp = try await inAppPaths(host: Self.awayHost)
        XCTAssertTrue(inApp.isEmpty, "and the app never did; saw \(inApp)")
    }

    /// F6 §4.1a: *Allow widget CDNs* off is the original one-origin promise,
    /// intact. Flipped in Settings in the same process that compiled the
    /// allowlisted list, so a list cached under an identifier without the
    /// CDN setting would be reused here and esm.sh fetched again.
    func testStrictModeBlocksTheAllowlistedCDNs() async throws {
        let app = try await launchSingleOrigin()
        defer { app.terminate() }
        let before = try await waitForSingleOriginSettled()
        XCTAssertEqual(before["cdn"] as? String, "ok", "the allowlist is on to begin with")

        let web = app.webViews.firstMatch
        let gear = app.buttons["settings-button"]
        if !gear.isHittable { drag(web, dy: 240) }
        XCTAssertTrue(gear.appears(within: 5) && gear.isHittable, "the gear is reachable")
        gear.tap()
        XCTAssertTrue(app.navigationBars["Settings"].appears(within: 10))
        let toggle = app.switches["allow-widget-cdns-toggle"]
        for _ in 0..<6 where !toggle.isHittable { app.swipeUp() }
        XCTAssertTrue(toggle.isHittable, "Settings → Privacy → Allow widget CDNs")
        XCTAssertEqual(toggle.value as? String, "1", "on by default")
        _ = try await Self.post("\(Self.dashboardControl)/__reset")
        _ = try await Self.post("\(Self.proxyControl)/reset")
        toggle.switches.firstMatch.tap()
        XCTAssertEqual(toggle.value as? String, "0", "switched off")
        app.navigationBars["Settings"].buttons["Done"].tap()

        let after = try await observe(try await waitForSingleOriginSettled(notDoc: before["doc"] as? String))
        XCTAssertNotEqual(after.report["cdn"] as? String, "ok", "esm.sh's script must not run in strict mode")
        let requests = after.requests
        XCTAssertEqual(requests["esm.sh"] ?? 0, 0, "strict mode fetches nothing from esm.sh; saw \(requests)")
        assertNothingReachedTheAwayOrigin("strict mode", in: after)
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

        // The document id of the page BEFORE sign-in. The assertion below
        // must come from a different document: without this, the old page's
        // last report (ws open, empty search) satisfies it and a broken
        // token strip passes (M2 review).
        let before = try await waitForReport(host: "dash.tail-scale.ts.net", timeout: 10) {
            $0["doc"] as? String != nil
        }
        let oldDoc = try XCTUnwrap(before["doc"] as? String, "the page reports a document id")

        let signIn = app.webViews.buttons["Sign in with token"]
        XCTAssertTrue(signIn.appears(within: 10), "the sign-in button should render")
        signIn.tap()

        // The server must see the token request: that is the sign-in.
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
            ($0["doc"] as? String).map { $0 != oldDoc } ?? false
        }
        XCTAssertNotEqual(report["doc"] as? String, oldDoc, "this report is from the new document")
        XCTAssertEqual(report["search"] as? String, "",
                       "the token must be gone from the address before the page's scripts run")
    }

    // MARK: - F9 §6: what the page is told about the safe area

    // MARK: - F12: the build names its commit

    /// Status names the commit the app was built from: the row read out when
    /// a TestFlight build misbehaves. scripts/test-offline.sh stamps it as
    /// make tf does; a build without LATCHKEY_GIT_SHA shows "—" here.
    func testStatusNamesTheCommitTheAppWasBuiltFrom() async throws {
        let app = launch(gateway: Self.gateway, suffix: Self.tailnetSuffix, peers: ["dash"])
        defer { app.terminate() }
        _ = try await waitForReport(host: "dash.tail-scale.ts.net", timeout: 30) { $0["ws"] as? String == "ws:open" }

        let list = app.openStatus()
        let commit = app.statusRow("diag-commit", in: list)
        XCTAssertNotNil(commit.firstMatch(of: /(^|[ ,])[0-9a-f]{12}(-dirty)?$/),
                        "Status names a 12-digit commit: \(commit)")
    }

    /// F9 §0.2: the web view is laid out inside the top safe area, so nothing
    /// is above the page and every probe — `viewport-fit=cover`, an ordinary
    /// page, and the product's complete viewport tag — is told a top inset of
    /// **0px**, with the web view's frame starting at the window's safe-area
    /// top plus the app bar (F15). The strip between the island and the page
    /// carries the page's own canvas colour, not a letterbox bar.
    ///
    /// This INVERTED on 2026-09-24. It used to record that the cover probe is
    /// told 62px with the frame at y=0: the web view was drawn under the island
    /// and the page trusted to inset itself, which KiroCrew 0.7.0's CSS does
    /// only as an installed web app. "Told 0" is the stronger assertion, not a
    /// weaker one: 0 is only right because the frame check proves the page is
    /// really below the island. Restoring `.ignoresSafeArea(.container, edges:
    /// .top)` in `BrowserView` fails it: cover and product report 62px again
    /// and the frame starts at 0.
    func testInsetProbesReportWhatThePageIsTold() async throws {
        addTeardownBlock { try? await Self.post("\(Self.dashboardControl)/__mode?root=page") }
        var seen: [String: [String: Any]] = [:]
        for probe in ["cover", "plain", "product"] {
            try await Self.post("\(Self.dashboardControl)/__mode?root=\(probe)")
            let app = launch(gateway: Self.gateway, suffix: Self.tailnetSuffix, peers: ["dash"],
                             extra: ["-UITestReportSafeArea"])
            // Several reports in, so layout has settled: the first can precede
            // the web view reaching its final frame.
            let r = try await waitForInsets(probe, timeout: 40) { ($0["seq"] as? Int ?? 0) >= 3 }

            let webView = app.webViews.firstMatch
            XCTAssertTrue(webView.appears(within: 10), "\(probe): the web view is on screen")
            let probeElement = app.descendants(matching: .any).matching(identifier: "window-safe-area").firstMatch
            XCTAssertTrue(probeElement.appears(within: 10), "\(probe): the safe-area probe is installed")
            let safeValue = probeElement.value as? String ?? ""
            let safeTop = Double(safeValue.replacingOccurrences(of: "top=", with: "")) ?? -1
            let minY = Double(webView.frame.minY)
            let bottomGap = Double(app.windows.firstMatch.frame.maxY - webView.frame.maxY)
            let strip = stripPixel(app, y: safeTop - 4)
            app.terminate()

            // Recorded before asserting: a failing run must still say what it measured.
            let line = "INSET-PROBE \(probe): top=\(r["top"] ?? "-") right=\(r["right"] ?? "-")"
                + " bottom=\(r["bottom"] ?? "-") left=\(r["left"] ?? "-")"
                + " innerHeight=\(r["innerHeight"] ?? "-") innerWidth=\(r["innerWidth"] ?? "-")"
                + " clientHeight=\(r["clientHeight"] ?? "-") visualViewportHeight=\(r["visualViewportHeight"] ?? "-")"
                + " kcTop=\(r["kcTop"] ?? "-") displayMode=\(r["displayMode"] ?? "-")"
                + " webViewMinY=\(minY) bottomGap=\(bottomGap) windowSafeTop=\(safeTop) strip=\(strip.map { "\($0)" } ?? "-")"
            print(line)
            add(XCTAttachment(string: line))
            // The simulator must have something above the page, or "told 0"
            // proves nothing: L1's iPhone 17 reports 62.
            XCTAssertGreaterThan(safeTop, 0, "\(probe): a device with a top safe area, got \(safeValue)")
            // F15: the app bar sits between the safe-area top and the page.
            XCTAssertEqual(minY, safeTop + Self.appBarHeight, accuracy: 0.5,
                           "\(probe): the web view starts below the app bar, not under the island")
            // F13: the page takes 10pt of the 34pt home-indicator inset, no more.
            XCTAssertEqual(bottomGap, 24, accuracy: 0.5,
                           "\(probe): the web view ends 24pt above the screen edge")
            XCTAssertEqual(r["top"] as? String, "0px",
                           "\(probe): nothing is above the page any more, so it is told a top inset of 0")
            for edge in ["right", "bottom", "left"] {
                let v = r[edge] as? String ?? ""
                XCTAssertTrue(v.hasSuffix("px") && Double(v.dropLast(2)) != nil,
                              "\(probe): env(safe-area-inset-\(edge)) is a computed length, got \(v)")
            }
            XCTAssertGreaterThan(r["innerHeight"] as? Int ?? 0, 0, "\(probe): a laid-out viewport")
            // The probe pages' canvas is rgb(32, 96, 160) (testing/harness/
            // dashboard.py); the system background is white or black.
            XCTAssertTrue(strip.map { abs($0.0 - 32) <= 6 && abs($0.1 - 96) <= 6 && abs($0.2 - 160) <= 6 } ?? false,
                          "\(probe): the strip above the web view is the page's own colour, got \(String(describing: strip))")
            seen[probe] = r
        }
        XCTAssertEqual(seen.count, 3, "every probe reported")
    }

    // MARK: - F15: Latchkey does not own the page's corners

    /// `AppBarRetraction.barHeight`. The UI test target cannot import the app,
    /// and a test that read the bar's height from the bar would pass a padded one.
    static let appBarHeight = 44.0

    /// F15 §6, all three of its tests, in both orientations, on one launch:
    ///
    /// 1. **Nothing of ours sits on the page.** Every hittable element of the
    ///    app's own — anything outside the web view's subtree — is swept, and
    ///    none may overlap the web view's frame. Shown to fail by putting the
    ///    gear back as an overlay on the web view's top-trailing corner: the
    ///    sweep names it and both rectangles.
    /// 2. **Settings is reachable**: the gear is hittable and opens Settings,
    ///    portrait and landscape, at most one scroll up away (the bar is absent
    ///    in the steady state).
    /// 3. **The top strip is no taller than it must be**: with the bar shown,
    ///    the web view's `minY` is the window's safe-area top plus the bar, and
    ///    no more. Shown to fail by padding the bar: both numbers are printed.
    ///
    /// First, untouched: the fake dashboard is too short to scroll, so it must
    /// have the bar without any gesture (F15 §4b), or the gear is unreachable
    /// on it. Last, it is dragged up deliberately and the bar must stay.
    func testNothingOfOursSitsOnThePageAndSettingsIsReachable() async throws {
        addTeardownBlock { @MainActor in XCUIDevice.shared.orientation = .portrait }
        let app = launch(gateway: Self.gateway, suffix: Self.tailnetSuffix, peers: ["dash"],
                         extra: ["-UITestReportSafeArea"])
        defer { app.terminate() }
        _ = try await waitForReport(host: "dash.tail-scale.ts.net", timeout: 30) { $0["ws"] as? String == "ws:open" }
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.appears(within: 10), "the web view is on screen")
        let gear = app.buttons["settings-button"]
        try await settle(app, web: web, landscape: false)
        // Longer than the page script's 500 ms measure: a report of a page
        // that scrolls would have hidden the bar by now.
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(Double(web.frame.minY), windowSafeTop(app) + Self.appBarHeight, accuracy: 0.5,
                       "a page too short to scroll has the bar untouched, or nothing could bring it in")
        XCTAssertTrue(gear.isHittable, "and the gear with it, no gesture needed")

        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            let name = orientation.isLandscape ? "landscape" : "portrait"
            XCUIDevice.shared.orientation = orientation
            try await settle(app, web: web, landscape: orientation.isLandscape)
            let safeTop = windowSafeTop(app)
            // One scroll up brings the bar in on any page. Whether the fake
            // scrolls in landscape is its font metrics' business; either way
            // the gear is this one gesture away, and no further.
            drag(web, dy: 240)
            _ = try await waitForMinY(web, safeTop + Self.appBarHeight, timeout: 5)
            try await settle(app, web: web, landscape: orientation.isLandscape)
            let webFrame = web.frame

            let line = "APP-BAR \(name): webViewFrame=\(webFrame) windowSafeTop=\(safeTop) barHeight=\(Self.appBarHeight)"
            print(line)
            add(XCTAttachment(string: line))

            let onThePage = try hittableControlsOverlapping(webFrame, in: app)
            XCTAssertTrue(onThePage.isEmpty,
                          "\(name): nothing of Latchkey's may sit on the page (web view \(webFrame)); on it: \(onThePage)")
            XCTAssertEqual(Double(webFrame.minY), safeTop + Self.appBarHeight, accuracy: 0.5,
                           "\(name): the page starts at the safe-area top plus the bar, and no lower: "
                           + "webViewMinY=\(webFrame.minY) windowSafeTop=\(safeTop) barHeight=\(Self.appBarHeight)")

            XCTAssertTrue(gear.appears(within: 5) && gear.isHittable,
                          "\(name): the gear is on screen and tappable")
            gear.tap()
            let settings = app.navigationBars["Settings"]
            XCTAssertTrue(settings.appears(within: 10), "\(name): the gear opens Settings")
            settings.buttons["Done"].tap()
            XCTAssertTrue(settings.disappears(within: 10), "\(name): and Settings closes again")
        }

        XCUIDevice.shared.orientation = .portrait
        try await settle(app, web: web, landscape: false)
        let safeTop = windowSafeTop(app)
        drag(web, dy: -240)
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(Double(web.frame.minY), safeTop + Self.appBarHeight, accuracy: 0.5,
                       "a page too short to scroll keeps the bar, however hard it is dragged")
        XCTAssertTrue(gear.isHittable, "and the gear with it")
    }

    /// F15 §4a/§4b on a page shaped like KiroCrew 0.7.0 — a full-height shell
    /// that never scrolls, with an inner scroller that does (`root=shell`). The
    /// page scrolls, so the bar is absent from the start and the page starts
    /// at the safe-area top. A 30 pt nudge changes nothing; a drag up of
    /// 240 pt scrolls the page and still changes nothing; a drag down of 240 pt
    /// brings the bar in, and another drag up takes it away. The page reports
    /// its own scroll position, which proves the drags reached it: the bar
    /// observes the gesture and never consumes it.
    ///
    /// Then again with `-UITestAssumeVoiceOver`, L1's stand-in for VoiceOver:
    /// the bar is there from the start, the same drag scrolls the page and the
    /// bar stays, with the gear hittable. Hidden must not mean gone for
    /// VoiceOver.
    func testTheAppBarRetractsOnADeliberateScrollAndComesBack() async throws {
        addTeardownBlock { try? await Self.post("\(Self.dashboardControl)/__mode?root=page") }
        try await Self.post("\(Self.dashboardControl)/__mode?root=shell")
        for voiceOver in [false, true] {
            let who = voiceOver ? "VoiceOver" : "no VoiceOver"
            _ = try await Self.post("\(Self.dashboardControl)/__reset")
            let app = launch(gateway: Self.gateway, suffix: Self.tailnetSuffix, peers: ["dash"],
                             extra: ["-UITestReportSafeArea"] + (voiceOver ? ["-UITestAssumeVoiceOver"] : []))
            _ = try await waitForInsets("shell", timeout: 40) { ($0["seq"] as? Int ?? 0) >= 2 }
            let web = app.webViews.firstMatch
            XCTAssertTrue(web.appears(within: 10), "\(who): the web view is on screen")
            let gear = app.buttons["settings-button"]
            let safeTop = windowSafeTop(app)
            let shown = safeTop + Self.appBarHeight
            if voiceOver {
                XCTAssertEqual(Double(web.frame.minY), shown, accuracy: 0.5,
                               "VoiceOver: the bar is on screen from the start")
            } else {
                // Inverted by the steady-state change: the page scrolls, so
                // the bar is not there until a scroll up asks for it.
                let start = try await waitForMinY(web, safeTop, timeout: 5)
                XCTAssertEqual(start, safeTop, accuracy: 0.5,
                               "the bar starts absent on a page that scrolls: the page starts at the safe-area top")
                XCTAssertFalse(gear.exists && gear.isHittable, "absent, the gear is not offered where it is not")
                drag(web, dy: 30)
                try await Task.sleep(for: .seconds(1))
                XCTAssertEqual(Double(web.frame.minY), safeTop, accuracy: 0.5, "a 30 pt nudge leaves the bar away")
            }

            drag(web, dy: -240)
            let r = try await waitForInsets("shell", timeout: 10) { Self.number($0["scrollTop"]) > 100 }
            let line = "APP-BAR-SCROLL \(who): scrollTop=\(r["scrollTop"] ?? "-") scrollRange=\(r["scrollRange"] ?? "-")"
                + " innerHeight=\(r["innerHeight"] ?? "-") webViewMinY=\(web.frame.minY) windowSafeTop=\(safeTop)"
            print(line)
            add(XCTAttachment(string: line))
            XCTAssertGreaterThan(Self.number(r["scrollTop"]), 100, "\(who): the drag scrolled the page: it was not consumed")

            if voiceOver {
                try await Task.sleep(for: .seconds(1))
                XCTAssertEqual(Double(web.frame.minY), shown, accuracy: 0.5,
                               "VoiceOver: the bar never retracts, so Settings is never off screen")
                XCTAssertTrue(gear.isHittable, "VoiceOver: the gear stays hittable after a scroll")
            } else {
                try await Task.sleep(for: .seconds(1))
                XCTAssertEqual(Double(web.frame.minY), safeTop, accuracy: 0.5, "scrolling down keeps the bar away")
                drag(web, dy: 240)
                let back = try await waitForMinY(web, shown, timeout: 5)
                XCTAssertEqual(back, shown, accuracy: 0.5, "a deliberate scroll up brings the bar in")
                XCTAssertTrue(gear.appears(within: 5) && gear.isHittable, "and the gear with it")
                let up = try await waitForInsets("shell", timeout: 10) {
                    Self.number($0["scrollTop"]) < Self.number(r["scrollTop"]) - 100
                }
                XCTAssertLessThan(Self.number(up["scrollTop"]), Self.number(r["scrollTop"]) - 100,
                                  "and that drag scrolled the page back up: it was not consumed either")
                drag(web, dy: -240)
                let away = try await waitForMinY(web, safeTop, timeout: 5)
                XCTAssertEqual(away, safeTop, accuracy: 0.5, "a deliberate scroll down takes it away again")
                XCTAssertFalse(gear.exists && gear.isHittable, "and the gear with it")
            }
            app.terminate()
        }
    }

    /// Olof, on the build of 2026-09-24: "when i tap the box to start typing,
    /// the keyboard comes up and everything else goes black on the dashboard."
    /// F13 padded the page by the stack's bottom safe area, and with the
    /// keyboard up that inset is the keyboard's height: the page was pushed up
    /// by the keyboard and then padded by it a second time, to a web view
    /// 0 pt tall (measured: frame (0, 106, 402, 0), keyboard top 590).
    ///
    /// Tap the fake's text field. With the keyboard up the page must still
    /// start below the bar and end at the keyboard's top edge. Shown to fail
    /// on 377c539 by the gap check; the simulator's screenshot still read
    /// white there, so the pixel check is a backstop, not the instrument.
    /// The fake is too short to scroll, so it has the bar, and the keyboard
    /// must not take it away: the extent reports that the shrunken viewport
    /// now scrolls are held while the keyboard is up.
    ///
    /// Then the same on the shell probe, which scrolls, so the bar starts
    /// absent: the keyboard up, a scroll up brings the bar in and a scroll
    /// down takes it away, and each time the page still ends at the
    /// keyboard's bars, the keyboard stays up and the field stays on screen.
    /// Showing the bar resizes the web view as the keyboard does, and a
    /// keyboard inset taken twice is what went black in 42af25d.
    func testTypingInThePageKeepsItOnScreen() async throws {
        addTeardownBlock { try? await Self.post("\(Self.dashboardControl)/__mode?root=page") }
        for root in ["page", "shell"] {
            try await Self.post("\(Self.dashboardControl)/__mode?root=\(root)")
            let app = launch(gateway: Self.gateway, suffix: Self.tailnetSuffix, peers: ["dash"],
                             extra: ["-UITestReportSafeArea"])
            let web = app.webViews.firstMatch
            XCTAssertTrue(web.appears(within: 30), "\(root): the web view is on screen")
            let safeTop = windowSafeTop(app)
            let field = web.textFields["Message"]
            XCTAssertTrue(field.appears(within: 30), "\(root): the page has a text field")
            if root == "shell" {
                let start = try await waitForMinY(web, safeTop, timeout: 5)
                XCTAssertEqual(start, safeTop, accuracy: 0.5, "shell: a page that scrolls starts without the bar")
            }
            field.tap()
            let keyboard = app.keyboards.firstMatch
            XCTAssertTrue(keyboard.appears(within: 10), "\(root): tapping the field brings up the keyboard")
            try await settle(app, web: web, landscape: false)
            // Longer than the page script's 500 ms measure of the new viewport.
            try await Task.sleep(for: .seconds(1))

            func check(_ step: String, barShown: Bool) {
                let webFrame = web.frame, keyboardTop = Double(keyboard.frame.minY)
                let midY = Double(webFrame.midY)
                // Right of the page's text, which is left-aligned and short.
                // The fake is white; the shell is its own blue, rgb(32, 96,
                // 160), under rows ruled in 20% white.
                let colour = pixel(app, x: Double(app.frame.width) - 24, y: midY)
                let line = "KEYBOARD \(root) \(step): webViewFrame=\(webFrame) keyboardTop=\(keyboardTop)"
                    + " windowSafeTop=\(safeTop) pixelAt(\(midY))=\(colour.map { "\($0)" } ?? "-")"
                print(line)
                add(XCTAttachment(string: line))
                add(XCTAttachment(screenshot: XCUIScreen.main.screenshot()))

                XCTAssertTrue(keyboard.exists, "\(root) \(step): the keyboard is still up")
                XCTAssertEqual(Double(webFrame.minY), safeTop + (barShown ? Self.appBarHeight : 0), accuracy: 0.5,
                               "\(root) \(step): the page starts " + (barShown ? "below the bar" : "at the safe-area top"))
                // XCUITest's keyboard is the keys alone. Above them sit the
                // prediction row and WebKit's form bar (^ v ✓), 112 pt on the
                // iPhone 17, and the page ends on top of those. 377c539 left
                // 484 pt; the home-indicator padding kept with the keyboard up
                // would leave 136.
                let gap = keyboardTop - Double(webFrame.maxY)
                XCTAssertTrue((0...120).contains(gap),
                              "\(root) \(step): the page ends just above the keyboard's bars, not \(gap) pt above the keys: \(line)")
                let (r, g, b) = colour ?? (0, 0, 0)
                XCTAssertTrue(root == "page" ? r > 200 && g > 200 && b > 200 : b > 120 && b > r + 60,
                              "\(root) \(step): the page is drawn between the top and the keyboard, not black: \(line)")
                XCTAssertTrue(field.isHittable, "\(root) \(step): and the field being typed into is on screen")
            }

            if root == "page" {
                check("keyboard up", barShown: true)
            } else {
                check("keyboard up", barShown: false)
                drag(web, dy: 150)
                _ = try await waitForMinY(web, safeTop + Self.appBarHeight, timeout: 5)
                try await settle(app, web: web, landscape: false)
                check("scrolled up", barShown: true)
                drag(web, dy: -150)
                _ = try await waitForMinY(web, safeTop, timeout: 5)
                try await settle(app, web: web, landscape: false)
                check("scrolled down", barShown: false)
            }
            app.terminate()
        }
    }

    /// Every hittable element outside the web view's subtree whose frame
    /// overlaps `webFrame` by more than a hairline, as "id-or-label frame".
    /// One snapshot for the tree; hittability is asked only of the overlaps.
    private func hittableControlsOverlapping(_ webFrame: CGRect, in app: XCUIApplication) throws -> [String] {
        let kinds: Set<XCUIElement.ElementType> = [.button, .link, .staticText, .image, .switch, .slider,
                                                  .textField, .secureTextField, .toggle, .menuButton]
        var overlapping: [(XCUIElement.ElementType, String, CGRect)] = []
        func walk(_ s: XCUIElementSnapshot) {
            if s.elementType == .webView { return }   // the page's own, whatever it draws
            if kinds.contains(s.elementType) {
                let i = s.frame.intersection(webFrame)
                if !i.isNull, i.width > 0.5, i.height > 0.5 {
                    overlapping.append((s.elementType, s.identifier.isEmpty ? s.label : s.identifier, s.frame))
                }
            }
            s.children.forEach(walk)
        }
        walk(try app.snapshot())
        return overlapping.compactMap { type, key, frame in
            let e = app.descendants(matching: type).matching(
                NSPredicate(format: "identifier == %@ OR label == %@", key, key)).firstMatch
            return e.exists && e.isHittable ? "\(key) \(frame)" : nil
        }
    }

    /// Waits for rotation and layout to finish: the app's frame has the
    /// orientation's shape and the web view's frame reads the same twice.
    private func settle(_ app: XCUIApplication, web: XCUIElement, landscape: Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        var last = CGRect.null
        while Date() < deadline {
            let f = app.frame
            let current = web.frame
            if (f.width > f.height) == landscape, current == last { return }
            last = current
            try await Task.sleep(for: .milliseconds(400))
        }
        XCTFail("layout did not settle in \(landscape ? "landscape" : "portrait"); app \(app.frame), web view \(last)")
    }

    private func windowSafeTop(_ app: XCUIApplication) -> Double {
        let probe = app.descendants(matching: .any).matching(identifier: "window-safe-area").firstMatch
        XCTAssertTrue(probe.appears(within: 10), "the safe-area probe is installed")
        let value = probe.value as? String ?? ""
        let top = Double(value.replacingOccurrences(of: "top=", with: ""))
        XCTAssertNotNil(top, "the safe-area probe reads a number: \(value)")
        return top ?? -1
    }

    /// A finger drag of `dy` points over the element's middle, held still at
    /// the end so it lifts with no momentum: a deliberate scroll, not a flick.
    private func drag(_ element: XCUIElement, dy: Double) {
        let start = element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: dy < 0 ? 0.75 : 0.3))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: dy)),
                    withVelocity: .slow, thenHoldForDuration: 0.3)
    }

    private func waitForMinY(_ element: XCUIElement, _ want: Double, timeout: TimeInterval) async throws -> Double {
        let deadline = Date().addingTimeInterval(timeout)
        var y = Double(element.frame.minY)
        while abs(y - want) > 0.5, Date() < deadline {
            try await Task.sleep(for: .milliseconds(200))
            y = Double(element.frame.minY)
        }
        return y
    }

    private static func number(_ v: Any?) -> Double { (v as? NSNumber)?.doubleValue ?? -1 }

    /// The screen's colour at the horizontal centre, `y` points down: below
    /// the island and above the web view when `y` is just short of the
    /// safe-area top. sRGB, 0–255.
    private func stripPixel(_ app: XCUIApplication, y: Double) -> (Int, Int, Int)? {
        pixel(app, x: Double(app.frame.width) / 2, y: y)
    }

    /// The screen's colour at (`x`, `y`) points. sRGB, 0–255.
    private func pixel(_ app: XCUIApplication, x: Double, y: Double) -> (Int, Int, Int)? {
        guard y > 0, let cg = XCUIScreen.main.screenshot().image.cgImage else { return nil }
        let scale = Double(cg.width) / Double(app.frame.width)
        let px = Int(x * scale), py = Int(y * scale)
        var rgba = [UInt8](repeating: 0, count: 4)
        let drawn: Bool = rgba.withUnsafeMutableBytes { buf in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(data: buf.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                                      bytesPerRow: 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            // CoreGraphics is bottom-up: shift the image so (px, py) lands on
            // the context's single pixel.
            ctx.draw(cg, in: CGRect(x: -px, y: py - cg.height + 1, width: cg.width, height: cg.height))
            return true
        }
        return drawn ? (Int(rgba[0]), Int(rgba[1]), Int(rgba[2])) : nil
    }

    private func waitForInsets(_ probe: String, timeout: TimeInterval,
                               until predicate: ([String: Any]) -> Bool) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        var last: [String: Any] = [:]
        while Date() < deadline {
            let insets = try await dashboardState()["insets"] as? [String: [String: Any]] ?? [:]
            if let r = insets[probe] {
                last = r
                if predicate(r) { return r }
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        XCTFail("no settled inset report from the \(probe) probe within \(Int(timeout))s; last: \(last)")
        return last
    }

    // MARK: - F11 §6: the first screen says what this is

    /// A fresh install, never logged in: the gate introduces the app, lists
    /// what happens after sign-in, and the button says what it does.
    /// Shown to fail by reverting ConnectionGateView to the pre-F11 gate: no
    /// `gate-intro`, and the button reads "Login".
    func testAFirstLaunchExplainsItself() throws {
        let app = launchAtTheGate()
        defer { app.terminate() }

        let button = app.buttons["login-button"]
        XCTAssertTrue(button.appears(within: 20), "the gate's sign-in button is shown")
        XCTAssertTrue(element(app, "gate-intro").exists, "a first launch shows the introduction")
        XCTAssertTrue(element(app, "gate-intro-steps").exists, "and its what-happens-next list")
        XCTAssertEqual(button.label, "Sign in to Tailscale", "the button names what it does")
        XCTAssertTrue(app.staticTexts["Tailscale Status"].exists, "the status section is still there")
    }

    /// The two things that stranded the owner on 2026-09-24, after a sign-in
    /// that worked: the new device needs approving, and it needs access to
    /// the dashboard's machine. Shown to fail by dropping either from
    /// `GateIntroduction.steps`: the message names the one that went missing.
    func testTheIntroductionNamesThePostLoginSteps() throws {
        let app = launchAtTheGate()
        defer { app.terminate() }

        let steps = element(app, "gate-intro-steps")
        XCTAssertTrue(steps.appears(within: 20), "the what-happens-next list is shown")
        let text = steps.label
        XCTAssertTrue(text.localizedCaseInsensitiveContains("approve"),
                      "the steps must say the new device may need approval; they read: \(text)")
        XCTAssertTrue(text.localizedCaseInsensitiveContains("access to the machine running the dashboard"),
                      "the steps must say it needs access to the dashboard's machine; they read: \(text)")
    }

    /// The standing test that copy on this screen cannot cost the user its
    /// only control (F11 §4.3): at the largest accessibility text size the
    /// sign-in button is on screen, hittable, and inside the window's safe
    /// area. Shown to fail by replacing the gate's ScrollView with a VStack:
    /// the words push the button below the screen.
    func testTheSignInButtonSurvivesItsOwnCopy() throws {
        let app = launchAtTheGate(extra: [
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
            "-UITestReportSafeArea",
        ])
        defer { app.terminate() }

        let button = app.buttons["login-button"]
        XCTAssertTrue(button.appears(within: 20), "the sign-in button exists at AccessibilityXXXL")
        XCTAssertTrue(element(app, "gate-intro").exists,
                      "the introduction is shown, or this test measures nothing")
        let window = app.windows.firstMatch.frame
        let safeTop = windowSafeTop(app)
        let safeBottom = windowSafeBottom(app)
        let safe = CGRect(x: window.minX, y: window.minY + safeTop, width: window.width,
                          height: window.height - safeTop - safeBottom)
        let frame = button.frame
        let line = "GATE-XXXL button=\(frame) window=\(window) safeTop=\(safeTop) safeBottom=\(safeBottom)"
        print(line)
        add(XCTAttachment(string: line))
        XCTAssertTrue(button.isHittable, "the sign-in button is hittable at AccessibilityXXXL: \(line)")
        XCTAssertTrue(safe.contains(frame), "the sign-in button lies inside the safe area: \(line)")
    }

    /// A user who has connected before, whose node is logged out again (key
    /// expiry), gets the terse gate: no introduction. Two real launches — the
    /// first reaches Running, which is what sets `hasEverConnected` — so the
    /// flag's write, its persistence and its read are all exercised. Shown to
    /// fail by passing `hasEverConnected: false` to the gate.
    func testAReturningUserIsNotReintroduced() throws {
        let first = launch(gateway: Self.gateway, suffix: Self.tailnetSuffix, peers: ["dash"])
        XCTAssertTrue(first.webViews.firstMatch.appears(within: 30),
                      "the first launch connects, which records that it has")
        first.terminate()

        let app = launch(gateway: Self.gateway, suffix: Self.tailnetSuffix, peers: ["dash"],
                         state: "NeedsLogin", reset: false)
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["login-button"].appears(within: 20), "the gate offers sign-in")
        XCTAssertTrue(app.staticTexts["Tailscale Status"].exists, "with its status section")
        XCTAssertFalse(element(app, "gate-intro").exists,
                       "a user who has connected before is not introduced to the app again")
    }

    private func launchAtTheGate(extra: [String] = []) -> XCUIApplication {
        launch(gateway: Self.gateway, suffix: Self.tailnetSuffix, peers: ["dash"],
               state: "NeedsLogin", extra: extra)
    }

    private func windowSafeBottom(_ app: XCUIApplication) -> Double {
        let probe = element(app, "window-safe-area-bottom")
        XCTAssertTrue(probe.appears(within: 10), "the bottom safe-area probe is installed")
        let value = probe.value as? String ?? ""
        let bottom = Double(value.replacingOccurrences(of: "bottom=", with: ""))
        XCTAssertNotNil(bottom, "the bottom safe-area probe reads a number: \(value)")
        return bottom ?? -1
    }

    // MARK: - F8 §6: a node that cannot start is a screen, not a crash

    /// The defect itself: a failed node start was a `fatalError`, so the app
    /// died at launch, every launch. Now it runs, says why, says nothing was
    /// deleted, counts its retries down — and stops counting after five.
    /// Shown to fail by restoring the `fatalError` in `nodeStartFailed`: the
    /// app is gone and XCUITest reports it not running.
    func testANodeThatCannotStartShowsAScreenInsteadOfDying() async throws {
        let launched = Date()
        let app = launch(gateway: Self.gateway, suffix: Self.tailnetSuffix, peers: ["dash"],
                         extra: ["-UITestNodeStartFails", "EACCES"])
        defer { app.terminate() }

        XCTAssertTrue(element(app, "node-start-failed").appears(within: 20), "G7 is shown")
        try await sleep(until: launched.addingTimeInterval(10))
        XCTAssertEqual(app.state, .runningForeground, "the app is still running 10 s after launch")
        XCTAssertTrue(element(app, "node-start-failed-cause").label.contains("storage permissions"),
                      "the cause names permissions: \(element(app, "node-start-failed-cause").label)")
        XCTAssertTrue(element(app, "node-start-nothing-deleted").label.contains("Nothing has been deleted"),
                      "the screen says nothing was deleted")
        XCTAssertTrue(app.buttons["node-start-retry-now"].exists, "Try now is offered")
        XCTAssertTrue(app.buttons["node-start-logs"].exists, "and Logs")
        XCTAssertFalse(element(app, "gate-starting-hint").exists, "not G2's 'still starting' over a node that won't exist")
        XCTAssertFalse(app.buttons["login-button"].exists, "and no sign-in: there is no node to sign in")

        // 1 + 2 + 4 + 8 + 16 s after the first failure, the schedule is spent.
        XCTAssertTrue(element(app, "node-start-retry-stopped").appears(within: 40),
                      "the retries stop after five: no unbounded loop")
        XCTAssertFalse(element(app, "node-start-retry-countdown").exists, "and the countdown goes with them")
        XCTAssertTrue(app.buttons["node-start-retry-now"].exists, "while Try now stays")
        XCTAssertEqual(app.state, .runningForeground, "the app is still running")
    }

    /// A failure that clears on retry reaches the dashboard with no tap.
    /// Shown to fail by an empty retry schedule (one attempt): G7 stays and
    /// no page ever loads.
    func testTheNodeStartRetryIsVisibleAndSucceeds() async throws {
        let app = launch(gateway: Self.gateway, suffix: Self.tailnetSuffix, peers: ["dash"],
                         extra: ["-UITestNodeStartFailsTimes", "2"])
        defer { app.terminate() }

        XCTAssertTrue(element(app, "node-start-failed").appears(within: 20), "G7 is shown")
        XCTAssertTrue(element(app, "node-start-retry-countdown").exists, "with its countdown")
        _ = try await waitForReport(host: "dash.tail-scale.ts.net", timeout: 30) {
            $0["title"] as? String == "FAKE DASHBOARD"
        }
        XCTAssertFalse(element(app, "node-start-failed").exists, "G7 is gone once a start succeeds")
    }

    /// Try now does not wait out the backoff. Four failures leave an 8 s
    /// wait; the tap must reach the dashboard well inside it. Shown to fail
    /// by making `retryStartNow` a no-op: the page only arrives with the
    /// scheduled retry, after the bound.
    func testTryNowRestartsTheNodeImmediately() async throws {
        let app = launch(gateway: Self.gateway, suffix: Self.tailnetSuffix, peers: ["dash"],
                         extra: ["-UITestNodeStartFailsTimes", "4"])
        defer { app.terminate() }

        let countdown = element(app, "node-start-retry-countdown")
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline, (countdown.value as? String)?.hasPrefix("attempt=4 ") != true {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(countdown.value as? String, "attempt=4 next=8", "the fourth failure waits 8 s")
        let tapped = Date()
        app.buttons["node-start-retry-now"].tap()
        _ = try await waitForReport(host: "dash.tail-scale.ts.net", timeout: 5) {
            $0["title"] as? String == "FAKE DASHBOARD"
        }
        let took = Date().timeIntervalSince(tapped)
        add(XCTAttachment(string: "TRY-NOW tap→dashboard \(String(format: "%.1f", took)) s"))
        XCTAssertLessThan(took, 5, "Try now reached the dashboard in \(took) s, inside the 8 s backoff")
    }

    /// *Start a new node* moves the old identity aside, never deletes it —
    /// and does nothing at all unless the owner confirms. Shown to fail by
    /// making `setAside` a delete (no aside directory), and by skipping the
    /// confirmation (the cancel step finds the directory moved).
    func testStartingANewNodeMovesTheOldStateAsideAndKeepsIt() async throws {
        let first = launch(gateway: Self.gateway, suffix: Self.tailnetSuffix, peers: ["dash"])
        XCTAssertTrue(first.webViews.firstMatch.appears(within: 30), "the first launch creates the workspace")
        first.terminate()

        let state = try stateDirectory()
        let planted = state.appending(path: "planted-identity.bin")
        let bytes = Data((0..<4096).map { _ in UInt8.random(in: 0...255) })
        try bytes.write(to: planted)

        let app = launch(gateway: Self.gateway, suffix: Self.tailnetSuffix, peers: ["dash"],
                         reset: false, extra: ["-UITestNodeStartFails", "EACCES"])
        defer { app.terminate() }
        let newNode = app.buttons["node-start-new-node"]
        XCTAssertTrue(newNode.reveal(scrolling: app.scrollViews.firstMatch), "Start a new node is offered")

        // Dismissed: nothing on disk may move. iOS 26 presents the dialog as
        // a popover with no Cancel button; a tap outside it dismisses.
        newNode.tap()
        let confirm = app.buttons.matching(identifier: "node-start-new-node-confirm").firstMatch
        XCTAssertTrue(confirm.appears(within: 5), "the confirmation is shown")
        app.otherElements["PopoverDismissRegion"].tap()
        XCTAssertTrue(confirm.disappears(within: 5), "and dismissed")
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(try Data(contentsOf: planted), bytes, "a dismissed confirmation moves nothing")
        XCTAssertEqual(try asideDirectories(beside: state), [], "and sets nothing aside")

        newNode.tap()
        XCTAssertTrue(confirm.appears(within: 5), "the confirmation offers the move")
        confirm.tap()

        var aside: [URL] = []
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, aside.isEmpty {
            aside = try asideDirectories(beside: state)
            if aside.isEmpty { try await Task.sleep(for: .milliseconds(250)) }
        }
        XCTAssertEqual(aside.count, 1, "the old state directory is set aside, not deleted")
        let kept = try XCTUnwrap(aside.first).appending(path: "planted-identity.bin")
        XCTAssertEqual(try? Data(contentsOf: kept), bytes, "with the old node's files in it, byte for byte")
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: state.path, isDirectory: &isDir) && isDir.boolValue,
                      "and a fresh state/ is in its place")
        XCTAssertFalse(FileManager.default.fileExists(atPath: planted.path), "which does not hold the old files")
        XCTAssertEqual(app.state, .runningForeground, "the app is still running")
    }

    /// The real thing, not the hook: the workspace's state directory made
    /// unreadable from the host, the real tsnet start, and a real failure —
    /// which arrives with no errno, only Go's "permission denied". Shown to
    /// fail by restoring the `fatalError` (the app is gone), and is the one
    /// test proving the hook models the real failure.
    func testAnUnwritableStateDirectoryIsSurvived() async throws {
        let first = launch(gateway: Self.gateway, suffix: Self.tailnetSuffix, peers: ["dash"])
        XCTAssertTrue(first.webViews.firstMatch.appears(within: 30), "the first launch creates the workspace")
        first.terminate()

        let state = try stateDirectory()
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: state.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: state.path)
        }

        // No fixture: the real node starts. Its control URL is a dead
        // loopback port, so were the start to succeed it would reach nothing.
        let app = XCUIApplication()
        app.launchArguments = [
            "-UITestHomePage", Self.gateway,
            "-TestControlURL", "http://127.0.0.1:9",
        ]
        app.launch()
        defer { app.terminate() }

        XCTAssertTrue(element(app, "node-start-failed").appears(within: 20), "G7 is shown")
        let cause = element(app, "node-start-failed-cause").label
        XCTAssertTrue(cause.contains("storage permissions"), "the real failure names permissions: \(cause)")
        try await Task.sleep(for: .seconds(3))
        XCTAssertEqual(app.state, .runningForeground, "the app is still running")
    }

    /// No node is ever created while process logging is unavailable (F8
    /// §4.6): its filch redacts tsnet's stderr. So G7 with the log-files
    /// sentence and no countdown, the log saying no node was started, and
    /// ZERO traffic — before and after Try now. Shown to fail by letting the
    /// start carry on after reporting the refusal: the fixture node starts
    /// and the proxy sees the dashboard's CONNECT.
    func testLoggingSetupFailureStopsTheNodeRatherThanStartingItBlind() async throws {
        let launched = Date()
        let app = launch(gateway: Self.gateway, suffix: Self.tailnetSuffix, peers: ["dash"],
                         extra: ["-UITestLoggingSetupFails"])
        defer { app.terminate() }

        // Traffic first: a start that carried on would also replace the gate
        // with the dashboard, and the G7 check would hide what matters.
        // Ten seconds is past where a started node's page has dialled.
        try await sleep(until: launched.addingTimeInterval(10))
        var connects = try await journalConnects()
        XCTAssertTrue(connects.isEmpty, "no node means no traffic: the proxy saw \(connects)")
        try await assertZeroRequests(host: "dash.tail-scale.ts.net")

        XCTAssertTrue(element(app, "node-start-failed").appears(within: 20), "G7 is shown")
        let cause = element(app, "node-start-failed-cause").label
        XCTAssertTrue(cause.contains("can't open its own log files"), "the cause is the logging refusal: \(cause)")
        XCTAssertFalse(element(app, "node-start-retry-countdown").exists, "with no countdown")
        XCTAssertFalse(app.buttons["node-start-new-node"].exists, "and no new node, which would not help")

        app.buttons["node-start-retry-now"].tap()
        try await Task.sleep(for: .seconds(5))
        XCTAssertTrue(element(app, "node-start-failed").exists, "Try now is refused again")
        connects = try await journalConnects()
        XCTAssertTrue(connects.isEmpty, "nor after Try now: the proxy saw \(connects)")
        try await assertZeroRequests(host: "dash.tail-scale.ts.net")

        app.buttons["node-start-logs"].tap()
        let refused = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "NODE START REFUSED: process logging is unavailable")).firstMatch
        XCTAssertTrue(refused.appears(within: 10), "the app log records that no node was started")
    }

    /// The only workspace's `state/`, in the app's container. The simulator's
    /// test runner reads the filesystem as the host user.
    private func stateDirectory() throws -> URL {
        let root = try appSupportDirectory()
        let data = try Data(contentsOf: root.appending(path: "workspaces.json"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let list = try XCTUnwrap(json["workspaces"] as? [[String: Any]], "workspaces.json lists workspaces")
        XCTAssertEqual(list.count, 1, "one workspace, as -UITestResetWorkspaces seeds")
        let id = try XCTUnwrap(list.first?["id"] as? String)
        return root.appending(path: "Workspaces/\(id)/state", directoryHint: .isDirectory)
    }

    private func appSupportDirectory() throws -> URL {
        // .../Containers/Data/Application/<runner>/ → its siblings.
        let applications = URL(fileURLWithPath: NSHomeDirectory()).deletingLastPathComponent()
        let fm = FileManager.default
        for dir in try fm.contentsOfDirectory(at: applications, includingPropertiesForKeys: nil) {
            let meta = dir.appending(path: ".com.apple.mobile_container_manager.metadata.plist")
            guard let plist = NSDictionary(contentsOf: meta),
                  plist["MCMMetadataIdentifier"] as? String == "net.lixom.latchkey" else { continue }
            return dir.appending(path: "Library/Application Support/Latchkey-UI-Test-iOS",
                                 directoryHint: .isDirectory)
        }
        throw NSError(domain: "OfflineHarnessTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "the app's container is not visible from the test runner"])
    }

    private func asideDirectories(beside state: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: state.deletingLastPathComponent(),
                                                    includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("state-aside-") }
    }

    // MARK: - Launch

    /// `state` is the fixture's `BackendState`: `NeedsLogin` holds the app at
    /// the connection gate (F11). `reset: false` keeps the previous launch's
    /// workspace, for a test about what a returning user sees.
    private func launch(gateway: String, suffix: String, peers: [String],
                        state: String = "Running", reset: Bool = true,
                        extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = (reset ? ["-UITestResetWorkspaces"] : []) + [
            "-UITestHomePage", gateway,
            "-TestStatusFixture", Self.fixture(suffix: suffix, peers: peers, state: state),
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
    static func fixture(suffix: String, peers: [String], state: String = "Running") -> String {
        func node(_ name: String, _ octet: Int) -> [String: Any] {
            ["ID": "fixture-\(name)", "HostName": name, "DNSName": "\(name).\(suffix).",
             "TailscaleIPs": ["100.127.255.\(octet)"], "Online": true,
             "ExitNode": false, "ExitNodeOption": false]
        }
        var peerMap: [String: Any] = [:]
        for (i, p) in peers.enumerated() { peerMap["nodekey:fixture-\(p)"] = node(p, 10 + i) }
        let status: [String: Any] = [
            "Version": "fixture", "BackendState": state, "AuthURL": "",
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
        XCTAssertTrue(errorPage.appears(within: 40), message, file: file, line: line)
    }

    /// The proxy-gone tests are the only end-to-end proof of `allowFailover ==
    /// false`, and "an error page, and zero requests" is also what a load
    /// that failed BEFORE dialling leaves behind -- a bad URL, a policy
    /// refusal, a certificate it would not trust -- which says nothing about
    /// failover (review, 2026-09-23). So the failure must be the
    /// connection's. The error page prints the cause as `[NSURLErrorDomain
    /// <code>]`; measured over 25 runs each: -1009 with the relay in front
    /// (the relay accepted, tsnet's port refused it, the relay closed on
    /// WebKit) and -1004 without it (WebKit dialled the dead proxy itself);
    /// -1005 is the same family. -1000 is not: it is what a SOCKS failure
    /// REPLY produces (the blackholed test, which pins its cause through the
    /// proxy journal instead) and what a URL never dialled produces too.
    private static let connectionFailureCodes: Set<Int> = [
        NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet,
    ]

    private func assertConnectionFailure(_ app: XCUIApplication, _ message: String,
                                         file: StaticString = #filePath, line: UInt = #line) {
        // The domain and code moved under the Details disclosure when the page
        // was rebuilt (F4 §3.2): the owner gets a sentence, and the diagnosis is
        // there when it is wanted. So open it before reading the code — this
        // assertion is the only end-to-end proof that `allowFailover` is false
        // and that the failure is the CONNECTION's, and it keeps that job.
        let details = app.descendants(matching: .any).matching(identifier: "nav-error-details").firstMatch
        if details.appears(within: 5), details.isHittable {
            details.tap()
        }
        let cause = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "NSURLErrorDomain ")).firstMatch
        XCTAssertTrue(cause.appears(within: 5), "\(message): the error page names its NSURLError code",
                      file: file, line: line)
        let label = cause.label
        let tail = label.components(separatedBy: "NSURLErrorDomain ").last ?? ""
        let code = Int(tail.trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first ?? "")
        XCTAssertTrue(code.map { Self.connectionFailureCodes.contains($0) } ?? false,
                      "\(message): the load must fail at the CONNECTION (-1004, -1005 or -1009), not before dialling; the error page says: \(label)",
                      file: file, line: line)
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

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// Sleeps until an absolute instant, so checkpoints are timed from the
    /// triggering event rather than accumulating each assertion's own cost
    /// (F4 §6). Returns at once if the instant has passed.
    private func sleep(until when: Date) async throws {
        let remaining = when.timeIntervalSinceNow
        if remaining > 0 { try await Task.sleep(for: .milliseconds(Int(remaining * 1000))) }
    }

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

    // Both go through HarnessControl (UITestSupport.swift), which fails on any
    // non-2xx. The copy that used to live here checked the status on GET and
    // not on POST, so a control call to an endpoint that did not exist was
    // silently a no-op.
    private static func get(_ url: String) async throws -> Data {
        try await HarnessControl.get(url)
    }

    @discardableResult
    private static func post(_ url: String) async throws -> Data {
        try await HarnessControl.post(url)
    }
}
