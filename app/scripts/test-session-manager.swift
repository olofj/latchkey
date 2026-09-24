// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

// Host tests for App/Session/SessionManager.swift: the session check is
// bounded (M4, R30). Run by scripts/test-session-manager.sh.
//
// The failure that shipped: a connection to the gateway that was open but
// answered nothing. The check's fetch had no timeout, so `verify` never
// returned, R30's `onUnansweredCheck` never fired, and the token sheet kept a
// spinner with Sign in disabled across close-and-reopen. Sign-out, which
// always passed a timeout, kept working -- the protection existed and was
// wired to one of two call paths.
//
// `SilentPage` is that connection: its fetch resolves only through the abort a
// timeout arms. Given no timeout it never resolves, so against the old code
// the first scenario below fails by its own deadline instead of hanging.

import Foundation
import WebKit

var failures = 0
var checks = 0
func expect(_ cond: Bool, _ what: String) {
    checks += 1
    if !cond { failures += 1; print("  FAIL \(what)") }
}

/// Polls `condition` until it holds or `limit` passes.
func waitUntil(_ condition: () -> Bool, within limit: Duration) async -> Bool {
    let deadline = ContinuousClock.now + limit
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return condition()
}

/// The gateway's page, as the session layer sees it, over a connection that
/// is open and answers nothing unless told otherwise.
final class SilentPage: SessionHost {
    struct Call: Equatable { let path: String; let method: String; let timeout: Duration? }
    var sessionOrigin: URL? = URL(string: "https://gw.tail-scale.ts.net")
    private(set) var calls: [Call] = []
    /// What successive fetches answer once their abort would have fired;
    /// nil is "no answer". Empty: no answer, ever.
    var answers: [Int?] = []
    private(set) var loaded: [URL] = []
    /// Fetches given no timeout, suspended for good. Held so the runtime does
    /// not report a dropped continuation: the suspension is the point.
    private var hung: [CheckedContinuation<Void, Never>] = []

    func loadSessionURL(_ url: URL) { loaded.append(url) }
    func revealSessionBanner() {}

    func sessionFetchStatus(_ path: String, method: String, timeout: Duration?) async -> Int? {
        calls.append(Call(path: path, method: method, timeout: timeout))
        guard timeout != nil else {
            // No abort armed: nothing ever resolves this fetch. This is the
            // shipped connection, not a fake's convenience.
            await withCheckedContinuation { hung.append($0) }
            return nil
        }
        // The abort fired (or the gateway answered): resolve at once. The
        // real timeout's length is asserted separately; waiting it out here
        // would only make the suite slow.
        return answers.isEmpty ? nil : answers.removeFirst()
    }
}

/// A SessionManager wired to `page` the way BrowserViewModel.makeWebView wires
/// it: without `install` there is no host, every check answers nil at once,
/// and a test would pass against any code.
func makeSession(for page: SilentPage) -> SessionManager {
    let session = SessionManager()
    session.install(into: WKUserContentController(), host: page)
    return session
}

let checkPath = "/api/auth/me"
let deadline: Duration = .seconds(6)   // well past two checks and the 1 s retry pause

print("== a page that answers nothing (the shipped failure)")
do {
    let page = SilentPage()
    let session = makeSession(for: page)
    var unanswered = 0
    session.onUnansweredCheck = { unanswered += 1 }
    session.navigationFinished()   // state != active: the M4 check
    let reported = await waitUntil({ unanswered >= 1 }, within: deadline)
    expect(reported, "onUnansweredCheck fires (R30: the relay gets probed) instead of the check hanging")
    expect(page.calls.count == 2, "the check and its one retry: \(page.calls.count) fetch(es)")
    expect(page.calls.allSatisfy { $0.path == checkPath && $0.method == "GET" },
           "both are GET \(checkPath): \(page.calls)")
    expect(page.calls.allSatisfy { $0.timeout == SessionManager.checkTimeout },
           "each carries SessionManager.checkTimeout, never nil: \(page.calls.map { $0.timeout.map(String.init(describing:)) ?? "nil" })")
    expect(unanswered == 1, "reported once per unanswered pair, not per fetch: \(unanswered)")
    expect(session.state == .unknown && !session.isTokenSheetPresented && session.message == nil,
           "an unanswered check decides nothing: no state, no sheet, no message")
}

print("== the timeout, from the evidence")
expect(SessionManager.checkTimeout >= .seconds(2),
       "not so short that a relayed path fails it (\(SessionManager.checkTimeout))")
expect(SessionManager.checkTimeout * 2 + .seconds(1) <= DashboardSignOut.requestTimeout,
       "two checks and the retry pause fit inside the sign-out's single bounded request (\(SessionManager.checkTimeout) x2 + 1 s vs \(DashboardSignOut.requestTimeout))")

print("== no answer, then an answer")
do {
    let page = SilentPage()
    let session = makeSession(for: page)
    var unanswered = 0
    session.onUnansweredCheck = { unanswered += 1 }
    page.answers = [nil, 200]
    session.navigationFinished()
    let active = await waitUntil({ session.state == .active }, within: deadline)
    expect(active, "a check that times out once and answers 200 on the retry marks the session active")
    expect(unanswered == 0, "and nothing is reported unanswered: \(unanswered)")
    expect(page.calls.count == 2, "two fetches: \(page.calls.count)")
}

print("== a refusal is an answer")
do {
    let page = SilentPage()
    let session = makeSession(for: page)
    var unanswered = 0
    session.onUnansweredCheck = { unanswered += 1 }
    page.answers = [403]
    session.navigationFinished()
    _ = await waitUntil({ page.calls.count >= 1 }, within: deadline)
    try? await Task.sleep(for: .milliseconds(300))
    expect(page.calls.count == 1 && unanswered == 0 && session.state == .unknown,
           "a 403 is an answer: no retry, not unanswered, and outside a redemption it changes nothing")
}

print("== a sign-in whose check goes unanswered keeps waiting")
do {
    let page = SilentPage()
    let session = makeSession(for: page)
    var unanswered = 0
    session.onUnansweredCheck = { unanswered += 1 }
    expect(session.redeem("abcdefghijklmnopqrstuvwxyz0123", pasteboardChangeCount: nil),
           "a bare token is accepted for redemption")
    expect(session.isRedeeming && page.loaded.count == 1 && page.loaded[0].query?.hasPrefix("token=") == true,
           "the sign-in navigation went to the gateway")
    session.navigationFinished()   // the sign-in load finished: verify(afterRedemption: true)
    let reported = await waitUntil({ unanswered >= 1 }, within: deadline)
    expect(reported, "the post-sign-in check is bounded too, and reports unanswered")
    expect(session.isRedeeming && session.message == nil,
           "an unanswered check does not fail the redemption: the 30 s timer decides, and says the gateway did not answer")
    session.reset()
}

print("== sign-out stays bounded")
do {
    let page = SilentPage()
    let session = makeSession(for: page)
    page.answers = [200]
    let status = await session.requestLogout()
    expect(status == 200, "the gateway's answer is returned: \(status.map(String.init) ?? "nil")")
    expect(page.calls == [SilentPage.Call(path: "/api/auth/logout", method: "POST", timeout: DashboardSignOut.requestTimeout)],
           "POST /api/auth/logout with DashboardSignOut.requestTimeout: \(page.calls)")
}

print(failures == 0 ? "\(checks)/\(checks) session manager checks passed" : "\(failures) of \(checks) session manager checks FAILED")
exit(failures == 0 ? 0 : 1)
