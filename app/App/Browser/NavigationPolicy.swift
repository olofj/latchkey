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
            // mailto:, tel:, sms:, maps:, app links — the system knows what
            // to do with these, and none of them can render in this view.
            return .openExternally
        }
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

    /// What the owner is told for a refused status. 502/503/504 are
    /// `tailscale serve` answering for a Kiro Crew that is not running; 500 is
    /// Kiro Crew itself failing on the document. Naming which one it is saves
    /// the owner from debugging the tailnet when the gateway is simply down.
    nonisolated static func refusalText(status: Int, host: String) -> String {
        switch status {
        case 502, 503, 504:
            return "\(host) answered, but Kiro Crew isn't running behind it (HTTP \(status)). "
                + "The tailnet and the gateway are fine — start Kiro Crew on that machine, then try again."
        default:
            return "Kiro Crew on \(host) failed to build the page (HTTP \(status)). "
                + "The tailnet and the connection are fine; check the gateway's own log."
        }
    }
}
