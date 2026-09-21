// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

//
//  SessionManager.swift
//  Latchkey
//
//  The dashboard session, as the app sees it (PLAN M4.3; revisions R5, R20,
//  R21, R22, R23).
//
//  It does NOT refresh the session — the page does, proactively ~1 h before
//  `session_exp` and on any 403 + `X-Auth-Required`, single-flight (R20). A
//  second refresher here would race the page's and could revoke the chain,
//  and behind `tailscale serve` every client shares one 60/min refresh bucket.
//  It persists nothing either (R5): the session is the web view's cookies.
//
//  What it does:
//   - Listens to the page through the session bridge (PageScriptSources).
//   - `mc-auth-required` → needsToken: the native sheet replaces the page's
//     banner, which the bridge hides with CSS (R22).
//   - `mc-auth-cleared` does NOT mean healthy — it fires when the banner is
//     dismissed, and a silent refresh fires nothing (R21). The app returns to
//     `active` only when the page's own `/api/auth/me` answers 200, asked
//     from the app's content world. Asserting sign-in by API, never by
//     rendering (R38): the shell is a 200 when signed out too.
//   - Redeems a token by navigating the web view to `<gateway>/?token=…` —
//     always the selected gateway (R23). The token leaves the address at
//     document start (R2) and never touches disk (R1).
//   - The R22 handshake: if a gateway document commits and the bridge does
//     not say `ready` within `handshakeTimeout`, the page's own banner is put
//     back, so a broken bridge cannot leave the user with no way to sign in.
//

import Combine
import Foundation
import WebKit
#if canImport(UIKit)
import UIKit
#endif

/// What the session layer needs from the web view that shows the gateway.
@MainActor
protocol SessionHost: AnyObject {
    /// The gateway origin the main frame is allowed to show (R3), if known.
    var sessionOrigin: URL? { get }
    /// Navigates the main frame to a same-origin URL (a sign-in link).
    func loadSessionURL(_ url: URL)
    /// `fetch(path, {method})`'s HTTP status, run in the app's content world
    /// with the page's cookies (PageScriptSources.sessionFetch). Nil when
    /// there is no page to ask, or none within `timeout` (nil: wait).
    func sessionFetchStatus(_ path: String, method: String, timeout: Duration?) async -> Int?
    /// Removes the bridge's banner-hiding style (the R22 fallback).
    func revealSessionBanner()
}

extension SessionHost {
    /// The M4 check: a GET, waited for.
    func sessionFetchStatus(_ path: String) async -> Int? {
        await sessionFetchStatus(path, method: "GET", timeout: nil)
    }
}

@MainActor
final class SessionManager: NSObject, ObservableObject {
    enum State: String {
        /// Not yet known: before the first page asked `/api/auth/me`.
        case unknown
        /// `/api/auth/me` answered 200.
        case active
        /// The page asked for a token (`mc-auth-required`).
        case needsToken
    }

    @Published private(set) var state: State = .unknown
    /// The REQUEST to show the sheet. Presentation can be deferred (Settings
    /// is open), so views that must know whether the sheet is actually up
    /// read `isTokenSheetOnScreen`.
    @Published var isTokenSheetPresented = false
    /// Set by the sheet itself (onAppear/onDisappear).
    @Published var isTokenSheetOnScreen = false
    /// How many `mc-auth-required` events arrived (test builds show it, so a
    /// sheet that flashes up and away between two looks is still caught).
    @Published private(set) var authRequiredEvents = 0
    /// The last thing worth telling the user on the sheet, if any.
    @Published private(set) var message: String?
    @Published private(set) var isRedeeming = false

    /// The content world the bridge runs in. The page cannot reach its
    /// message handler.
    static let world = WKContentWorld.world(name: "latchkey-session")
    static let messageName = "kiroSession"
    static let handshakeTimeout: Duration = .seconds(8)
    static let redemptionTimeout: Duration = .seconds(30)

    private weak var host: SessionHost?
    /// Called when `/api/auth/me` got no answer twice in a row (R30 review):
    /// a page-world fetch that fails says nothing about why, and the tsnet
    /// manager uses it as its cue to probe the SOCKS relay's listener, which
    /// the page cannot report on. Changes nothing here.
    var onUnansweredCheck: (() -> Void)?
    private var readySinceNavigationStart = false
    private var watchdog: Task<Void, Never>?
    private var redemption: Redemption?
    private var redemptionTimer: Task<Void, Never>?
    /// Bumped by every `mc-auth-required`. A check started before the bump
    /// cannot mark the session active: the page has spoken since (M4 review).
    private var authGeneration = 0

    private struct Redemption {
        /// `UIPasteboard.changeCount` when the token was pasted; nil when it
        /// was typed or scanned. See `clearPasteboardIfUnchanged`.
        let pasteboardChangeCount: Int?
    }

    /// The host name the sheet shows as the sign-in target.
    var gatewayHost: String? { host?.sessionOrigin?.host }

    /// Forgets the current gateway's sign-in state (a new gateway was chosen,
    /// or the session was signed out, R32). `notice` is what the sheet shows
    /// when the page next asks for a token: sign-out's "on this device only".
    func reset(notice: String? = nil) {
        watchdog?.cancel()
        redemptionTimer?.cancel()
        redemption = nil
        isRedeeming = false
        message = notice
        state = .unknown
        isTokenSheetPresented = false
        authGeneration += 1
    }

    /// Asks the gateway to end the session (R32), as the page: the refresh
    /// cookie is scoped to /api/auth and HttpOnly, and the CSRF check wants
    /// the page's Origin, so only a page-world POST revokes the chain there.
    /// The status, or nil when there is no page or it did not answer in time.
    /// Local data is the caller's to clear; this changes no state here.
    func requestLogout() async -> Int? {
        guard let host else { return nil }
        let status = await host.sessionFetchStatus("/api/auth/logout", method: "POST",
                                                   timeout: DashboardSignOut.requestTimeout)
        logger.log("Session: logout asked of the gateway: \(status.map(String.init) ?? "no answer")")
        return status
    }

    // MARK: - Installation

    /// Adds the bridge to a web view's configuration. Call before its first
    /// navigation.
    func install(into controller: WKUserContentController, host: SessionHost) {
        self.host = host
        controller.addUserScript(WKUserScript(source: PageScriptSources.sessionBridge,
                                              injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true,
                                              in: Self.world))
        controller.add(WeakScriptMessageHandler(self), contentWorld: Self.world, name: Self.messageName)
    }

    // MARK: - Navigation (from the web view's delegate, main frame only)

    func navigationStarted() {
        readySinceNavigationStart = false
        watchdog?.cancel()
    }

    func navigationCommitted() {
        guard !readySinceNavigationStart else { return }
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: Self.handshakeTimeout)
            guard !Task.isCancelled, let self, !self.readySinceNavigationStart else { return }
            logger.log("Session bridge: no handshake within \(Self.handshakeTimeout); showing the page's own banner")
            self.host?.revealSessionBanner()
        }
    }

    func navigationFinished() {
        if redemption != nil {
            Task { await verify(afterRedemption: true) }
        } else if state != .active {
            // A signed-in document fires no event: without this, a page that
            // recovered on its own would stay "needsToken" (M4 review).
            Task { await verify(afterRedemption: false) }
        }
    }

    /// The sign-in navigation itself failed (network, TLS): say so now rather
    /// than after the redemption timeout.
    func signInLoadFailed() {
        guard redemption != nil else { return }
        failRedemption(because: "Couldn't reach the gateway to sign in. Check the connection and try again.")
    }

    // MARK: - The bridge

    /// A message from the bridge. Only the gateway's main frame counts.
    func handleBridgeEvent(_ event: String, frame: WKFrameInfo) {
        guard frame.isMainFrame, Self.matches(frame.securityOrigin, host?.sessionOrigin) else {
            logger.log("Session bridge: ignoring \(event) from a frame that is not the gateway's main frame")
            return
        }
#if LATCHKEY_TEST_HOOKS
        // Simulates a bridge whose messages never arrive (R22's fallback).
        if TestHooks.flag("-UITestBreakSessionBridge") { return }
#endif
        switch event {
        case "ready":
            readySinceNavigationStart = true
            watchdog?.cancel()
            if state != .active { Task { await verify(afterRedemption: false) } }
        case "auth-required":
            logger.log("Session: the page needs a token")
            authRequiredEvents += 1
            authGeneration += 1
            if redemption != nil {
                // Any script on the page can dispatch this event. While a
                // sign-in is in flight, believe it only if the server agrees.
                Task { await confirmAuthRequiredDuringRedemption() }
                return
            }
            state = .needsToken
            isTokenSheetPresented = true
        case "auth-cleared":
            // Not a signal of health (R21): ask.
            Task { await verify(afterRedemption: false) }
        default:
            logger.log("Session bridge: unknown event \(event)")
        }
    }

    // MARK: - Token entry

    /// Signs in with pasted, typed or scanned input. Returns false (and sets
    /// `message`) if the input holds no usable token.
    @discardableResult
    func redeem(_ input: String, pasteboardChangeCount: Int?) -> Bool {
        guard let parsed = TokenInput.parse(input) else {
            message = "That doesn't contain a sign-in token. Paste the link `kirocrew token` prints, or the token itself."
            return false
        }
        guard let origin = host?.sessionOrigin,
              let url = TokenInput.signInURL(origin: origin, token: parsed.token)
        else {
            message = "Not connected to the gateway yet. Try again in a moment."
            return false
        }
        message = nil
        redemption = Redemption(pasteboardChangeCount: pasteboardChangeCount)
        isRedeeming = true
        redemptionTimer?.cancel()
        redemptionTimer = Task { [weak self] in
            try? await Task.sleep(for: Self.redemptionTimeout)
            guard !Task.isCancelled, let self, self.redemption != nil else { return }
            // Ask once before calling it a failure: a slow relay can finish
            // the load after the timer (M4 review).
            await self.verify(afterRedemption: true)
            guard self.redemption != nil else { return }
            self.failRedemption(because: "The gateway did not answer. Check the connection and try again.")
        }
        logger.log("Session: redeeming a token at \(origin.redactedForLog)")
        host?.loadSessionURL(url)
        return true
    }

    /// Whether the pasted input names a host other than the gateway it will
    /// be used with (shown on the sheet before signing in, R23).
    func foreignLinkHost(in input: String) -> String? {
        guard let linkHost = TokenInput.parse(input)?.linkHost?.lowercased(),
              let gateway = gatewayHost?.lowercased(),
              linkHost != gateway,
              !Self.isLocalCLIHost(linkHost)
        else { return nil }
        return linkHost
    }

    // MARK: - Verification

    private func verify(afterRedemption: Bool) async {
        let generation = authGeneration
        var status = await host?.sessionFetchStatus("/api/auth/me")
        if status == nil {
            // One retry: a single failed fetch must not strand the session.
            try? await Task.sleep(for: .seconds(1))
            status = await host?.sessionFetchStatus("/api/auth/me")
        }
        guard let status else {
            onUnansweredCheck?()
            return
        }
        if status == 200 {
            guard generation == authGeneration else {
                logger.log("Session: ignoring a stale check; the page asked for a token since")
                return
            }
            if state != .active { logger.log("Session: active") }
            state = .active
            isTokenSheetPresented = false
            message = nil
            if let r = redemption {
                clearPasteboardIfUnchanged(r.pasteboardChangeCount)
                redemption = nil
                redemptionTimer?.cancel()
                isRedeeming = false
            }
        } else if afterRedemption, redemption != nil {
            failRedemption()
        }
    }

    private func confirmAuthRequiredDuringRedemption() async {
        let status = await host?.sessionFetchStatus("/api/auth/me")
        if status == 200 {
            logger.log("Session: auth-required during sign-in, but the session answers; ignored")
            return
        }
        if redemption != nil { failRedemption() }
        state = .needsToken
        isTokenSheetPresented = true
    }

    private func failRedemption(because reason: String? = nil) {
        redemption = nil
        redemptionTimer?.cancel()
        isRedeeming = false
        message = reason ?? "That sign-in link didn't work. Links last 5 minutes and work only on the gateway that made them — get a fresh one and try again."
        isTokenSheetPresented = true
    }

    /// Clears the clipboard after a successful sign-in, but only if it still
    /// holds what was pasted (R23): Universal Clipboard has synced that link
    /// to every device. The change count is compared instead of the content,
    /// because reading the content would raise the paste prompt.
    private func clearPasteboardIfUnchanged(_ changeCount: Int?) {
#if canImport(UIKit)
        guard let changeCount, UIPasteboard.general.changeCount == changeCount else { return }
        UIPasteboard.general.items = []
        logger.log("Session: cleared the pasted sign-in link from the clipboard")
#endif
    }

    // MARK: - Helpers

    /// `kirocrew token` prints a localhost link first; its host is not a
    /// warning sign.
    private static func isLocalCLIHost(_ host: String) -> Bool {
        ["localhost", "127.0.0.1", "::1", "[::1]", "kirocrew.localhost"].contains(host)
    }

    static func matches(_ origin: WKSecurityOrigin, _ allowed: URL?) -> Bool {
        guard let allowed, let scheme = allowed.scheme?.lowercased(), let host = allowed.host?.lowercased()
        else { return false }
        let defaultPort = scheme == "https" ? 443 : (scheme == "http" ? 80 : 0)
        let allowedPort = allowed.port ?? defaultPort
        let originPort = origin.port == 0 ? defaultPort : origin.port
        return origin.protocol.lowercased() == scheme
            && origin.host.lowercased() == host
            && originPort == allowedPort
    }
}

/// Breaks the retain cycle WKUserContentController would otherwise create: it
/// holds its message handlers strongly.
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: SessionManager?
    init(_ target: SessionManager) { self.target = target }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let event = body["event"] as? String else { return }
        target?.handleBridgeEvent(event, frame: message.frameInfo)
    }
}
