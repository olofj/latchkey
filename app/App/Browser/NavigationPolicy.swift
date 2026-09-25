// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

//
//  NavigationPolicy.swift
//  Latchkey
//
//  "Exactly one destination", enforced (revision R3, finding H2).
//
//  Upstream allowed every navigation. In a chrome-less view with no address
//  bar, that means a link in agent output — or anything the dashboard renders —
//  can replace the dashboard with a page of its choosing, and the user has no
//  way to tell. A spoofed "your session expired, paste your token" page there
//  is a clean phishing surface. So the main frame may show the gateway's
//  origin and nothing else; everything else leaves the app.
//
//  Sub-frames are deliberately left alone: the dashboard renders widgets in
//  same-origin `/sandbox-doc/` iframes, and a frame cannot take over the view.
//
//  Pure Foundation so `scripts/test-navigation-policy.sh` compiles it alone.
//

import Foundation

enum NavigationDecision: Equatable, Sendable {
    /// Let WebKit load it here.
    case allow
    /// Cancel here and hand the URL to the system (Safari, Mail, Phone…).
    case openExternally
    /// Cancel and do nothing else.
    case cancel
}

enum NavigationPolicy {
    /// Decides a navigation.
    ///
    /// - Parameters:
    ///   - url: the navigation's target.
    ///   - isMainFrame: true for the top-level document, and for a request to
    ///     open a new window (which would be a top-level document too).
    ///   - allowedOrigin: the origin the app itself last loaded, as produced
    ///     by `GatewayAddress.origin(of:)`. Taken from the app's own resolved
    ///     load rather than the raw setting, because a bare configured name
    ///     (`http://gateway`) is expanded to its FQDN before loading — checking
    ///     against the raw value would send the app's own first load to Safari.
    nonisolated static func decide(url: URL?, isMainFrame: Bool,
                                   allowedOrigin: String?) -> NavigationDecision {
        guard let url, let scheme = url.scheme?.lowercased() else { return .cancel }

        guard isMainFrame else { return .allow }

        switch scheme {
        case "about":
            // about:blank is the unreachable-gateway fallback page. Nothing
            // else under about: is reachable as a main-frame navigation.
            return .allow
        case "http", "https":
            guard let allowedOrigin,
                  let target = GatewayAddress.origin(of: url.absoluteString)
            else { return .openExternally }
            return target == allowedOrigin ? .allow : .openExternally
        case "blob":
            // A blob URL carries its creator's origin
            // (blob:https://host/uuid). Same-origin blobs are the dashboard's
            // own content, e.g. a generated download; anything else is not.
            let inner = String(url.absoluteString.dropFirst("blob:".count))
            guard let allowedOrigin, GatewayAddress.origin(of: inner) == allowedOrigin
            else { return .cancel }
            return .allow
        case "data", "javascript", "file":
            // data: can be a whole document with no origin to check against;
            // javascript: and file: have no business in the main frame.
            return .cancel
        default:
            // mailto:, tel:, sms:, maps:, app links — none of them can render
            // in this view. Whether one is actually handed on, and whether
            // the owner is asked first, is `HandOffPolicy`'s call (R42).
            return .openExternally
        }
    }
}

enum HandOffDecision: Equatable, Sendable {
    /// Hand it to the system now.
    case open
    /// Ask the owner first (F17 §2's prompt).
    case ask
    /// Hand it to nothing.
    case refuse
}

/// What happens to a URL `NavigationPolicy` sent out of the app (R42, F17).
///
/// R3 handed every such URL to `UIApplication.shared.open`, with no prompt,
/// whatever its scheme and whoever started it — so a page script setting
/// `location = "shortcuts://run-shortcut?…"` ran a shortcut with no tap.
///
/// Silent only for schemes where opening changes nothing until the owner acts
/// again in the other app (Safari shows a page, Mail opens a draft, iOS asks
/// before dialling), and only when a tap started it. An unknown app scheme is
/// asked even when tapped, because a script can navigate from inside the
/// owner's own click; untapped, it is refused, because a prompt nobody caused
/// is how an owner is talked into tapping Open.
enum HandOffPolicy {
    nonisolated static let silentSchemes: Set<String> = ["http", "https", "mailto", "tel"]
    /// Never handed on. `NavigationPolicy` does not send these; refused here
    /// again because this is the last decision before another app.
    nonisolated static let neverSchemes: Set<String> = ["javascript", "data", "file", "blob", "about"]

    /// - Parameters:
    ///   - userStarted: a trusted tap started it (`TransientActivation`), or a
    ///     native control of the app's own did.
    ///   - untappedAsksMuted: the owner cancelled an untapped ask and has not
    ///     tapped since. A page that was told no does not get to ask again.
    nonisolated static func decide(url: URL?, userStarted: Bool,
                                   untappedAsksMuted: Bool) -> HandOffDecision {
        guard let scheme = url?.scheme?.lowercased(), !neverSchemes.contains(scheme)
        else { return .refuse }
        if silentSchemes.contains(scheme) {
            if userStarted { return .open }
            return untappedAsksMuted ? .refuse : .ask
        }
        return userStarted ? .ask : .refuse
    }
}

/// The owner's last trusted click, as the page's activation reporter posts it
/// (F17 §4.2). Good for one hand-off within `window` of the click.
///
/// Not `WKNavigationAction.navigationType`: a script's `a.click()` reports
/// `.linkActivated` exactly as a finger does, and a real tap on a button
/// whose handler sets `location` reports `.other`.
struct TransientActivation: Sendable {
    /// A tap's own navigation reaches the policy in milliseconds. Longer only
    /// widens what a script can piggyback; a tapped link that arrives later
    /// (a slow redirect) degrades to a prompt, not to a dead link.
    nonisolated static let window: Duration = .seconds(1)

    private var last: ContinuousClock.Instant?

    nonisolated init() {}

    nonisolated mutating func record(at now: ContinuousClock.Instant) {
        last = now
    }

    /// True when a click at most `window` old is pending; clears it either way.
    nonisolated mutating func consume(at now: ContinuousClock.Instant) -> Bool {
        defer { last = nil }
        guard let last else { return false }
        return now - last <= Self.window
    }
}

enum ResponseDecision: Equatable, Sendable { case commit, refuse }

/// Which main-frame *responses* commit as the document (F4 §4.13).
///
/// `NavigationPolicy` decides requests; this decides responses, **by status
/// alone**, in the main frame alone. It exists because the response delegate
/// used to `.allow` everything without looking: the gateway is published
/// through `tailscale serve`, whose reverse proxy has no error handler, so a
/// Kiro Crew restart answers **502 on a live port 443**. TCP and TLS succeed,
/// so no `NSURLError` is produced, `SocksRelayPolicy`'s transport codes never
/// fire, and the empty 502 body commits as the document — a blank page with no
/// overlay, no retry and no relay verdict. That is a second, faster path to the
/// blank screen F4 was written about (state D10).
///
/// Pure Foundation, in this file, so `scripts/test-navigation-policy.sh`
/// compiles and tests it on the host.
enum ResponsePolicy {
    /// - Parameters:
    ///   - isMainFrame: sub-frames are the page's own business; a widget's 502
    ///     is the widget's problem, exactly as `NavigationPolicy` leaves
    ///     sub-frame *requests* alone.
    ///   - statusCode: nil for anything that is not an HTTP response
    ///     (`about:blank`, a scheme handler, a blob) — nothing to inspect.
    ///   - authRequired: the `X-Auth-Required: true` header, KiroCrew's own
    ///     signature for "you are not signed in". **Always commits**, whatever
    ///     the status: it is the very shape discovery uses to recognise a
    ///     gateway, its body is KiroCrew's sign-in page, and refusing it would
    ///     turn a gateway-refused sign-in ("that link didn't work") into
    ///     "couldn't reach the gateway" — telling the owner the tailnet is
    ///     broken when the gateway said no.
    nonisolated static func decide(isMainFrame: Bool, statusCode: Int?,
                                   authRequired: Bool) -> ResponseDecision {
        guard isMainFrame, let status = statusCode else { return .commit }
        if authRequired { return .commit }
        // Only 5xx is refused. A gateway that is up and answering — however
        // unhappily — always gets to show its own page; only a gateway that is
        // not there is replaced by ours. 304 is never a failure: it is the
        // document the web view already holds.
        return (500...599).contains(status) ? .refuse : .commit
    }

    // `refusalText` lived here and is gone (F4 §3.2). It was a SECOND wording
    // for a refused 5xx beside `PageFailureText.lines(for:)`'s, and once the
    // rebuilt error page read the latter, the former was displayed nowhere while
    // still being maintained and tested. Two texts for one state drift, and the
    // one that drifts is the one nobody sees. The wording now lives in
    // PageFailureText, tested there, including that 502 and 500 do not read
    // alike.
}
