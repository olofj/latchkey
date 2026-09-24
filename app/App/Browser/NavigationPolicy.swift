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
