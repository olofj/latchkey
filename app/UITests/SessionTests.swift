// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

//
//  SessionTests.swift
//  LatchkeyUITests
//
//  M4: the dashboard session, against KiroCrew's REAL 0.6.0 frontend (R19).
//
//  The page is the installed KiroCrew bundle, served byte for byte by
//  testing/harness/fake_gateway.py, which emulates the server's auth
//  contract (redemption, 403 + X-Auth-Required, rotation with a grace window,
//  chain revocation, the `boot` claim, the rate limit). Its refresh
//  scheduler, 403 interceptor, `mc-auth-*` events and banner are the real
//  ones. The app reaches it the L1 way: `-TestStatusFixture` with a `gw` peer
//  and the stub SOCKS5 proxy, which maps gw.tail-scale.ts.net to the fake.
//
//  Observation (R13): the fake's control port reports redemptions,
//  rotations, `/api/auth/me` successes and LINEAGE VIOLATIONS — any reuse of
//  a superseded refresh token outside the grace window, the R25 hazard. The
//  app's own UI (sheet, sign-in button) is read from the accessibility tree;
//  the page's banner is looked for there too, since `display:none` removes it.
//
//  Sign-in is asserted by the server (`/api/auth/me` answered 200, a
//  redemption happened), never by rendering (R38): the shell is a 200 when
//  signed out too.
//
//  Needs the offline harness AND the fake gateway: scripts/test-session.sh
//  (parent repo).
//

import UIKit
import XCTest

@MainActor
final class SessionTests: XCTestCase {

    static let gatewayControl = "http://127.0.0.1:8481"
    static let proxyControl = "http://127.0.0.1:1081"
    static let gateway = "https://gw.tail-scale.ts.net"
    static let gatewayHost = "gw.tail-scale.ts.net"

    /// The page's own banner input; present in the tree only when visible.
    static let bannerPlaceholder = "Paste token URL or raw token…"

    override func setUp() async throws {
        continueAfterFailure = false
        guard (try? await Self.get("\(Self.gatewayControl)/__state")) != nil,
              (try? await Self.get("\(Self.proxyControl)/journal")) != nil
        else {
            XCTFail("The fake gateway or the offline harness is not running. Use scripts/test-session.sh (parent repo).")
            return
        }
        _ = try await Self.post("\(Self.gatewayControl)/__reset")
        _ = try await Self.post("\(Self.proxyControl)/mode?blackhole=0")
        _ = try await Self.post("\(Self.proxyControl)/open")
    }

    // MARK: - R22: the native sheet replaces the page's banner

    func testSignedOutShowsTheNativeSheetAndHidesThePageBanner() async throws {
        let app = launch()
        defer { app.terminate() }

        let sheet = element(app, "token-sheet")
        XCTAssertTrue(sheet.waitForExistence(timeout: 30), "signed out: the native sheet appears")
        // LabeledContent merges its label into the element: "Signing in to, <host>".
        let target = element(app, "token-sheet-target").label
        XCTAssertTrue(target.hasSuffix(Self.gatewayHost),
                      "the sheet names the gateway it will sign in to (R23); got \(target)")
        element(app, "token-sheet-close").tap()
        XCTAssertTrue(element(app, "session-signin-button").waitForExistence(timeout: 5),
                      "with the sheet closed, the app keeps a way to sign in")
        // Past the 8 s handshake watchdog, so a healthy bridge is shown not to
        // trigger the fallback (M4 review). Positive control for this query:
        // testABrokenBridgeLeavesThePageBannerVisible.
        try await Task.sleep(for: .seconds(11))
        XCTAssertFalse(app.webViews.textFields[Self.bannerPlaceholder].exists,
                       "the page's own banner stays hidden (CSS only), past the watchdog")
        element(app, "session-signin-button").tap()
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "the button reopens the sheet")
    }

    /// R22's fallback, and the positive control for the hidden-banner check:
    /// with no bridge messages arriving, the app puts the page's banner back
    /// after the handshake timeout, and the banner IS visible to this query.
    func testABrokenBridgeLeavesThePageBannerVisible() async throws {
        let app = launch(extra: ["-UITestBreakSessionBridge"])
        defer { app.terminate() }

        XCTAssertTrue(app.webViews.textFields[Self.bannerPlaceholder].waitForExistence(timeout: 40),
                      "no handshake: the page's own banner must be shown as the fallback")
        XCTAssertFalse(element(app, "token-sheet").exists, "no bridge, no native sheet")
    }

    // MARK: - M4.4 / R23: token entry

    /// `kirocrew token` prints several URLs; pasting all of them signs in to
    /// the selected gateway, and the clipboard is cleared afterwards.
    func testPastingCLIOutputSignsIn() async throws {
        let app = launch()
        defer { app.terminate() }
        XCTAssertTrue(element(app, "token-sheet").waitForExistence(timeout: 30))

        try await signIn(app, kind: "cli")
        let state = try await gatewayState()
        XCTAssertEqual(counter(state, "redemptions"), 1, "exactly one redemption")
        XCTAssertGreaterThanOrEqual(counter(state, "app_auth_checks"), 1, "the app confirmed the session by API (R21, R38)")
        XCTAssertFalse(UIPasteboard.general.hasStrings, "the pasted sign-in link is cleared from the clipboard (R23)")
        XCTAssertFalse(element(app, "session-signin-button").exists)
    }

    /// A dead link (expired, or for another gateway) says so, and the sheet
    /// stays up.
    func testABadTokenSaysSoAndKeepsTheSheet() async throws {
        let app = launch()
        defer { app.terminate() }
        XCTAssertTrue(element(app, "token-sheet").waitForExistence(timeout: 30))

        typeToken(app, "\(Self.gateway)/?token=fk1.not-a-link-this-gateway-made")
        let message = element(app, "token-sheet-message")
        XCTAssertTrue(message.waitForExistence(timeout: 20), "a failed sign-in explains itself")
        XCTAssertTrue(message.label.contains("didn't work"), message.label)
        XCTAssertTrue(element(app, "token-sheet").exists, "the sheet stays up")
        let redemptions = counter(try await gatewayState(), "redemptions")
        XCTAssertEqual(redemptions, 0)
    }

    // MARK: - R20 / R25: the page keeps the session alive by itself

    /// Short-lived access sessions: the real scheduler refreshes about every
    /// 5 s (it aims for exp − 1 h, floored at 5 s). Across ~40 s the sheet
    /// never appears (counted, not sampled), rotations are counted, and no
    /// superseded refresh token is ever reused.
    func testThePageRefreshesAcrossExpiriesWithoutTheSheet() async throws {
        _ = try await Self.post("\(Self.gatewayControl)/__config?expire_in=6")
        let app = launch()
        defer { app.terminate() }
        XCTAssertTrue(element(app, "token-sheet").waitForExistence(timeout: 30))
        try await signIn(app, kind: "cli")
        let start = try await gatewayState()
        let asked = authRequiredCount(app)

        try await Task.sleep(for: .seconds(40))
        let end = try await gatewayState()
        XCTAssertEqual(authRequiredCount(app), asked,
                       "the page never asked for a token (counted, so a flash between looks is caught)")
        XCTAssertFalse(element(app, "token-sheet").exists)
        let rotations = counter(end, "rotations") - counter(start, "rotations")
        XCTAssertGreaterThanOrEqual(rotations, 5, "the page must have refreshed repeatedly; saw \(rotations)")
        XCTAssertEqual(violations(end), 0, "no superseded refresh token reused: \(end["violations"] ?? [])")
        XCTAssertEqual(counter(end, "redemptions"), 1, "no re-sign-in happened")
    }

    /// The other recovery path: the 403 interceptor. With a session far from
    /// expiry, the scheduler's next refresh is ~400 s away (exp − 1 h), so
    /// after a forced expiry the page's own 30 s poll is the first to hit
    /// the 403, and the interceptor must refresh -- no sheet. (Inside the
    /// short-session test the scheduler usually cured the expiry first, so
    /// the 403 path ran only by luck: M5 regression run.)
    func testAnExpiredSessionIsRecoveredByThePagesInterceptor() async throws {
        _ = try await Self.post("\(Self.gatewayControl)/__config?expire_in=4000")
        let app = launch()
        defer { app.terminate() }
        XCTAssertTrue(element(app, "token-sheet").waitForExistence(timeout: 30))
        try await signIn(app, kind: "cli")
        let asked = authRequiredCount(app)
        let before = try await gatewayState()

        _ = try await Self.post("\(Self.gatewayControl)/__expire")
        var after = before
        for _ in 0..<50 {
            try await Task.sleep(for: .seconds(1))
            after = try await gatewayState()
            if counter(after, "denials") > counter(before, "denials"),
               counter(after, "rotations") > counter(before, "rotations") { break }
        }
        XCTAssertGreaterThan(counter(after, "denials"), counter(before, "denials"),
                             "the expired session hit a 403 (the interceptor's trigger)")
        XCTAssertGreaterThan(counter(after, "rotations"), counter(before, "rotations"),
                             "and the page refreshed in response")
        XCTAssertEqual(authRequiredCount(app), asked, "silently: no token needed")
        XCTAssertEqual(violations(after), 0)
    }

    // MARK: - R21: the terminal path, and recovery

    func testARevokedChainShowsTheSheetAndANewTokenRecovers() async throws {
        _ = try await Self.post("\(Self.gatewayControl)/__config?expire_in=6")
        let app = launch()
        defer { app.terminate() }
        XCTAssertTrue(element(app, "token-sheet").waitForExistence(timeout: 30))
        try await signIn(app, kind: "cli")

        // Revoke the chain but leave the access session valid, as reuse
        // detection does: the page's scheduler is then the first to hit the
        // revoked chain (its refresh is due every ~5 s), which is the path
        // that reloads the page. Expiring access too would let the 403
        // interceptor get there first, with no reload -- a race.
        let shellLoads = counter(try await gatewayState(), "shell_loads")
        _ = try await Self.post("\(Self.gatewayControl)/__revoke")
        var reloaded = shellLoads
        for _ in 0..<20 where reloaded <= shellLoads {
            try await Task.sleep(for: .seconds(1))
            reloaded = counter(try await gatewayState(), "shell_loads")
        }
        XCTAssertGreaterThan(reloaded, shellLoads,
                             "refresh_chain_revoked reloads the page (location.assign('/'))")
        // The reloaded document's bridge must be there: when its access
        // session lapses, the sheet comes from THAT document.
        XCTAssertTrue(element(app, "token-sheet").waitForExistence(timeout: 60),
                      "a revoked chain ends in the native sheet, from the reloaded page")

        try await signIn(app, kind: "cli")
        let state = try await gatewayState()
        XCTAssertEqual(counter(state, "redemptions"), 2, "the second token redeemed")
        XCTAssertEqual(violations(state), 0, "the revocation was the gateway's, not a lineage violation")
        XCTAssertFalse(element(app, "token-sheet").exists)
    }

    // MARK: - R24: gateway restarts

    /// A CLI-link session carries no `boot` claim: it survives a restart and
    /// keeps refreshing, with no sheet.
    func testACLISessionSurvivesAGatewayRestart() async throws {
        _ = try await Self.post("\(Self.gatewayControl)/__config?expire_in=6")
        let app = launch()
        defer { app.terminate() }
        XCTAssertTrue(element(app, "token-sheet").waitForExistence(timeout: 30))
        try await signIn(app, kind: "cli")

        let asked = authRequiredCount(app)
        let wsBefore = counter(try await gatewayState(), "ws_opens")
        // A real restart: every connection drops and the gateway is gone for
        // a few seconds (M4 review: the zero-downtime restart proved less).
        _ = try await Self.post("\(Self.gatewayControl)/__restart?down=3")
        let before = counter(try await gatewayState(), "rotations")
        try await Task.sleep(for: .seconds(16))
        XCTAssertEqual(authRequiredCount(app), asked, "a CLI session must survive the restart")
        let wsAfter = counter(try await gatewayState(), "ws_opens")
        XCTAssertGreaterThan(wsAfter, wsBefore,
                             "the page's WebSocket reconnected after the restart")
        let after = counter(try await gatewayState(), "rotations")
        XCTAssertGreaterThan(after, before, "and keep rotating after it")
    }

    /// A QR-minted session is boot-bound: after a restart it ends, and the
    /// sheet appears.
    func testAQRSessionEndsAtAGatewayRestart() async throws {
        _ = try await Self.post("\(Self.gatewayControl)/__config?expire_in=6")
        let app = launch()
        defer { app.terminate() }
        XCTAssertTrue(element(app, "token-sheet").waitForExistence(timeout: 30))
        try await signIn(app, kind: "qr")

        _ = try await Self.post("\(Self.gatewayControl)/__restart")
        XCTAssertTrue(element(app, "token-sheet").waitForExistence(timeout: 45),
                      "a boot-bound session ends at a restart, and the app asks for a token")
    }

    // MARK: - Network loss is not a sign-out

    /// While the gateway is unreachable, refreshes fail at the network level —
    /// transient, not a 401 — so no sheet. When it comes back, the page
    /// recovers the session by itself.
    func testNetworkLossDoesNotShowTheSheet() async throws {
        _ = try await Self.post("\(Self.gatewayControl)/__config?expire_in=6")
        let app = launch()
        defer { app.terminate() }
        XCTAssertTrue(element(app, "token-sheet").waitForExistence(timeout: 30))
        try await signIn(app, kind: "cli")

        let asked = authRequiredCount(app)
        _ = try await Self.post("\(Self.proxyControl)/mode?blackhole=1")
        try await Task.sleep(for: .seconds(20))
        XCTAssertEqual(authRequiredCount(app), asked, "an unreachable gateway is not a sign-out")
        let before = counter(try await gatewayState(), "rotations")
        _ = try await Self.post("\(Self.proxyControl)/mode?blackhole=0")
        var recovered = false
        for _ in 0..<45 {
            try await Task.sleep(for: .seconds(2))
            XCTAssertFalse(element(app, "token-sheet").exists, "recovery must not need a token")
            if counter(try await gatewayState(), "rotations") > before { recovered = true; break }
        }
        XCTAssertTrue(recovered, "the page refreshed again once the gateway was reachable")
        XCTAssertEqual(authRequiredCount(app), asked, "recovery needed no token")
        let finalState = try await gatewayState()
        XCTAssertEqual(violations(finalState), 0)
    }

    // MARK: - M4 review: what real gateways do that the first fake did not

    /// `kirocrew logout` bumps the revocation generation: the access session
    /// AND the refresh chain are refused (401 invalid_refresh, no cookie
    /// clear, so no reload). The sheet comes through the page's 403
    /// interceptor, and a new token recovers.
    func testSignOutEverywhereShowsTheSheet() async throws {
        _ = try await Self.post("\(Self.gatewayControl)/__config?expire_in=6")
        let app = launch()
        defer { app.terminate() }
        XCTAssertTrue(element(app, "token-sheet").waitForExistence(timeout: 30))
        try await signIn(app, kind: "cli")

        _ = try await Self.post("\(Self.gatewayControl)/__logout-all")
        XCTAssertTrue(element(app, "token-sheet").waitForExistence(timeout: 45),
                      "signed out everywhere: the app asks for a token")
        try await signIn(app, kind: "cli")
        let redemptions = counter(try await gatewayState(), "redemptions")
        XCTAssertEqual(redemptions, 2)
    }

    /// A refresh the gateway carried out but whose response was lost: the
    /// page still holds the consumed token. Its next attempt comes inside
    /// the 60 s grace window, gets the same tokens re-served, and the session
    /// carries on — no sheet, no lineage violation.
    func testALostRefreshResponseIsRecoveredByTheGraceWindow() async throws {
        _ = try await Self.post("\(Self.gatewayControl)/__config?expire_in=6")
        let app = launch()
        defer { app.terminate() }
        XCTAssertTrue(element(app, "token-sheet").waitForExistence(timeout: 30))
        try await signIn(app, kind: "cli")
        let asked = authRequiredCount(app)

        _ = try await Self.post("\(Self.gatewayControl)/__drop-next-refresh")
        var state: [String: Any] = [:]
        for _ in 0..<30 {
            try await Task.sleep(for: .seconds(2))
            state = try await gatewayState()
            if counter(state, "refresh_dropped") > 0, counter(state, "grace_reserves") > 0 { break }
        }
        XCTAssertEqual(counter(state, "refresh_dropped"), 1, "a refresh response was lost")
        XCTAssertGreaterThanOrEqual(counter(state, "grace_reserves"), 1, "the retry came inside the grace window")
        XCTAssertEqual(violations(state), 0)
        XCTAssertEqual(authRequiredCount(app), asked, "no token needed")
    }

    /// The same lost response, but the gateway restarts before the retry:
    /// the grace cache is memory-only, so the retry looks like token reuse
    /// and the chain is revoked. KiroCrew behaviour, not something the app
    /// can prevent — what the app must do is recover through the sheet.
    func testALostRefreshAtARestartEndsInTheSheet() async throws {
        _ = try await Self.post("\(Self.gatewayControl)/__config?expire_in=6")
        let app = launch()
        defer { app.terminate() }
        XCTAssertTrue(element(app, "token-sheet").waitForExistence(timeout: 30))
        try await signIn(app, kind: "cli")

        _ = try await Self.post("\(Self.gatewayControl)/__drop-next-refresh")
        for _ in 0..<15 {
            try await Task.sleep(for: .seconds(1))
            if counter(try await gatewayState(), "refresh_dropped") > 0 { break }
        }
        _ = try await Self.post("\(Self.gatewayControl)/__restart")
        XCTAssertTrue(element(app, "token-sheet").waitForExistence(timeout: 75),
                      "the chain is revoked by the retry; the app asks for a token")
        let afterRestart = try await gatewayState()
        XCTAssertGreaterThanOrEqual(violations(afterRestart), 1,
                                    "the revocation came from the retried (superseded) token, as on a real gateway")
        try await signIn(app, kind: "cli")
    }

    // MARK: - Helpers

    private func launch(extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-UITestResetWorkspaces",
            "-UITestHomePage", Self.gateway,
            "-TestStatusFixture", OfflineHarnessTests.fixture(suffix: "tail-scale.ts.net", peers: ["gw"]),
            "-TestProxyEndpoint", OfflineHarnessTests.proxyEndpoint,
            "-TestProxyCredential", OfflineHarnessTests.proxyCredential,
            // Keep every test's web data: test-session.sh's R1 scan must see
            // all of it, not only the last test's (M4 review).
            "-UITestKeepWebData",
        ] + extra
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// Signs in the way a user does: mint a link at the gateway, put
    /// `kirocrew token`-shaped output on the clipboard, tap Paste.
    private func signIn(_ app: XCUIApplication, kind: String) async throws {
        let minted = try JSONSerialization.jsonObject(
            with: try await Self.post("\(Self.gatewayControl)/__mint?kind=\(kind)")) as? [String: Any]
        let url = try XCTUnwrap(minted?["url"] as? String)
        let link = try XCTUnwrap(minted?["link"] as? String)
        let before = counter(try await gatewayState(), "app_auth_checks")
        UIPasteboard.general.string = """
            Dashboard sign-in links (valid 5 minutes):
              http://localhost:5476/?token=\(link)
              \(url)
            """
        let paste = element(app, "token-paste-button").exists
            ? element(app, "token-paste-button")
            : app.buttons["Paste"].firstMatch
        XCTAssertTrue(paste.waitForExistence(timeout: 10), "the sheet offers Paste")
        paste.tap()
        XCTAssertTrue(element(app, "token-sheet").waitForNonExistence(timeout: 30),
                      "signing in dismisses the sheet")
        let after = counter(try await gatewayState(), "app_auth_checks")
        XCTAssertGreaterThan(after, before, "the APP confirmed the session with its own /api/auth/me")
    }

    /// How many times the page has asked for a token in this launch.
    private func authRequiredCount(_ app: XCUIApplication) -> Int {
        let marker = element(app, "session-auth-required-count")
        guard marker.waitForExistence(timeout: 5) else { return -1 }
        return Int(marker.label) ?? -1
    }

    private func typeToken(_ app: XCUIApplication, _ text: String) {
        let field = element(app, "token-input")
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(text)
        element(app, "token-submit").tap()
    }

    private func gatewayState() async throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: try await Self.get("\(Self.gatewayControl)/__state")) as? [String: Any] ?? [:]
    }

    private func counter(_ state: [String: Any], _ name: String) -> Int {
        (state["counters"] as? [String: Int])?[name] ?? 0
    }

    private func violations(_ state: [String: Any]) -> Int {
        (state["violations"] as? [Any])?.count ?? -1
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
