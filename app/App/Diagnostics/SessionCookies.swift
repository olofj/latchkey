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

    nonisolated static func summary(of cookies: [HTTPCookie], host: String) -> Summary {
        var out = Summary()
        for c in cookies where matches(domain: c.domain, host: host) {
            let found: Found = c.expiresDate.map { .expires($0) } ?? .untilQuit
            if c.name.hasPrefix("mc_token_") {
                out.access = later(out.access, found)
            } else if c.name.hasPrefix("mc_refresh_") {
                out.refresh = later(out.refresh, found)
            }
        }
        return out
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

    private nonisolated static func later(_ a: Found, _ b: Found) -> Found {
        switch (a, b) {
        case (.none, _): return b
        case (_, .none): return a
        case (.untilQuit, _), (_, .untilQuit): return .untilQuit
        case (.expires(let x), .expires(let y)): return .expires(max(x, y))
        }
    }
}
