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

import UIKit
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
            let strip = stripPixel(app, y: safeTop - 4)
            app.terminate()

            // Recorded before asserting: a failing run must still say what it measured.
            let line = "INSET-PROBE \(probe): top=\(r["top"] ?? "-") right=\(r["right"] ?? "-")"
                + " bottom=\(r["bottom"] ?? "-") left=\(r["left"] ?? "-")"
                + " innerHeight=\(r["innerHeight"] ?? "-") innerWidth=\(r["innerWidth"] ?? "-")"
                + " clientHeight=\(r["clientHeight"] ?? "-") visualViewportHeight=\(r["visualViewportHeight"] ?? "-")"
                + " kcTop=\(r["kcTop"] ?? "-") displayMode=\(r["displayMode"] ?? "-")"
                + " webViewMinY=\(minY) windowSafeTop=\(safeTop) strip=\(strip.map { "\($0)" } ?? "-")"
            print(line)
            add(XCTAttachment(string: line))
            // The simulator must have something above the page, or "told 0"
            // proves nothing: L1's iPhone 17 reports 62.
            XCTAssertGreaterThan(safeTop, 0, "\(probe): a device with a top safe area, got \(safeValue)")
            // F15: the app bar sits between the safe-area top and the page.
            XCTAssertEqual(minY, safeTop + Self.appBarHeight, accuracy: 0.5,
                           "\(probe): the web view starts below the app bar, not under the island")
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
    ///    portrait and landscape. Shown to fail by starting the bar retracted,
    ///    i.e. Settings behind a gesture.
    /// 3. **The top strip is no taller than it must be**: the web view's `minY`
    ///    is the window's safe-area top plus the bar, and no more. Shown to fail
    ///    by padding the bar: both numbers are printed.
    ///
    /// Then the fake dashboard, which is too short to scroll, is dragged up
    /// deliberately: the bar must stay (F15 §4b), or it could never come back.
    func testNothingOfOursSitsOnThePageAndSettingsIsReachable() async throws {
        addTeardownBlock { @MainActor in XCUIDevice.shared.orientation = .portrait }
        let app = launch(gateway: Self.gateway, suffix: Self.tailnetSuffix, peers: ["dash"],
                         extra: ["-UITestReportSafeArea"])
        defer { app.terminate() }
        _ = try await waitForReport(host: "dash.tail-scale.ts.net", timeout: 30) { $0["ws"] as? String == "ws:open" }
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.appears(within: 10), "the web view is on screen")
        let gear = app.buttons["settings-button"]

        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            let name = orientation.isLandscape ? "landscape" : "portrait"
            XCUIDevice.shared.orientation = orientation
            try await settle(app, web: web, landscape: orientation.isLandscape)
            let safeTop = windowSafeTop(app)
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
    /// that never scrolls, with an inner scroller that does (`root=shell`). A
    /// drag up of 240 pt retracts the bar and the page starts at the safe-area
    /// top; a drag back down returns it. A 30 pt nudge changes nothing. The page
    /// reports its own scroll position, which proves the drag reached it: the
    /// bar observes the gesture and never consumes it.
    ///
    /// Then again with `-UITestAssumeVoiceOver`, L1's stand-in for VoiceOver:
    /// the same drag scrolls the page and the bar stays, with the gear hittable.
    /// Retracted must not mean gone for VoiceOver.
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
            XCTAssertEqual(Double(web.frame.minY), shown, accuracy: 0.5, "\(who): the bar starts shown")

            if !voiceOver {
                drag(web, dy: -30)
                try await Task.sleep(for: .seconds(1))
                XCTAssertEqual(Double(web.frame.minY), shown, accuracy: 0.5, "a 30 pt nudge leaves the bar alone")
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
                let retracted = try await waitForMinY(web, safeTop, timeout: 5)
                XCTAssertEqual(retracted, safeTop, accuracy: 0.5,
                               "a deliberate drag up retracts the bar: the page starts at the safe-area top")
                XCTAssertFalse(gear.exists && gear.isHittable, "retracted, the gear is not offered where it is not")
                drag(web, dy: 240)
                let back = try await waitForMinY(web, shown, timeout: 5)
                XCTAssertEqual(back, shown, accuracy: 0.5, "a deliberate drag down brings the bar back")
                XCTAssertTrue(gear.appears(within: 5) && gear.isHittable, "and the gear with it")
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
        guard y > 0, let cg = XCUIScreen.main.screenshot().image.cgImage else { return nil }
        let scale = Double(cg.width) / Double(app.frame.width)
        let px = Int(Double(cg.width) / 2), py = Int(y * scale)
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
