// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

//
//  SessionCookies.swift
//  Latchkey
//
//  When the dashboard session ends (PLAN M8.2): the expiry of KiroCrew's two
//  session cookies for the chosen gateway, `mc_token_<port>` (access) and
//  `mc_refresh_<port>` (the session itself; the page refreshes access from
//  it). Foundation only, so scripts/test-diagnostics.sh compiles it on the
//  host.
//
//  Only names, domains and expiry dates are looked at. A cookie's value is a
//  credential and never leaves this function.
//

import Foundation

enum SessionCookies {
    enum Found: Equatable {
        case none
        /// A cookie with no expiry: it lasts as long as the web view's
        /// session. KiroCrew always sets Max-Age, so this is unexpected.
        case untilQuit
        case expires(Date)
    }

    struct Summary: Equatable {
        var access: Found = .none
        var refresh: Found = .none
    }

    /// The session for each cookie port on `host`. KiroCrew names its
    /// cookies after the port IT listens on (`mc_token_5476`), which behind
    /// `tailscale serve` is not the URL's port (R37), so the gateway URL
    /// cannot pick one. One port is the normal case; more means several
    /// dashboards, or an old port's cookies, on this host -- shown apart,
    /// never merged into one misleading date.
    nonisolated static func summaries(of cookies: [HTTPCookie], host: String) -> [String: Summary] {
        var out: [String: Summary] = [:]
        for c in cookies where matches(domain: c.domain, host: host) {
            let found: Found = c.expiresDate.map { .expires($0) } ?? .untilQuit
            if let port = c.name.stripPrefix("mc_token_") {
                out[port, default: Summary()].access = later(out[port, default: Summary()].access, found)
            } else if let port = c.name.stripPrefix("mc_refresh_") {
                out[port, default: Summary()].refresh = later(out[port, default: Summary()].refresh, found)
            }
        }
        return out
    }

    /// One Status value from `summaries`: the one session's, or one line per
    /// port.
    nonisolated static func describe(_ summaries: [String: Summary], _ part: KeyPath<Summary, Found>, now: Date) -> String {
        switch summaries.count {
        case 0: return describe(.none, now: now)
        case 1: return describe(summaries.first!.value[keyPath: part], now: now)
        default:
            return summaries.keys.sorted().map { "port \($0): " + describe(summaries[$0]![keyPath: part], now: now) }
                .joined(separator: "\n")
        }
    }

    /// `domain` as WebKit stores it: the host itself for a host-only cookie,
    /// or `.example.com` for a domain cookie.
    nonisolated static func matches(domain: String, host: String) -> Bool {
        let d = domain.lowercased(), h = host.lowercased()
        guard !h.isEmpty else { return false }
        if d == h { return true }
        guard d.hasPrefix(".") else { return false }
        return h == d.dropFirst() || h.hasSuffix(d)
    }

    nonisolated static func describe(_ found: Found, now: Date) -> String {
        switch found {
        case .none: return "none"
        case .untilQuit: return "until the app quits"
        case .expires(let d):
            let left = d.timeIntervalSince(now)
            let when = d.formatted(date: .abbreviated, time: .shortened)
            return left <= 0 ? "expired \(when)" : "\(when) (in \(Expiry.describe(left)))"
        }
    }

    /// Within one port, the longest-lived copy (a host-only and a domain
    /// cookie of the same name can both exist).
    private nonisolated static func later(_ a: Found, _ b: Found) -> Found {
        switch (a, b) {
        case (.none, _): return b
        case (_, .none): return a
        case (.untilQuit, _), (_, .untilQuit): return .untilQuit
        case (.expires(let x), .expires(let y)): return .expires(max(x, y))
        }
    }
}

private extension String {
    nonisolated func stripPrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
