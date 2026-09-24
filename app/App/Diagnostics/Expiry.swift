// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

//
//  Expiry.swift
//  Latchkey
//
//  The two clocks that silently end the app (revisions R31, R33), and when to
//  warn about them. Foundation only, so scripts/test-diagnostics.sh compiles
//  it on the host.
//
//   - The node key (R31). When it expires the node drops off the tailnet and
//     needs an interactive re-login. Warn 14 days ahead.
//   - The provisioning profile (R33). A free personal team signs for 7 days;
//     when the profile expires the app simply stops launching. Warn 48 hours
//     ahead, while there is still time to rebuild from Xcode.
//

import Foundation

enum Expiry {
    nonisolated static let keyWarning: TimeInterval = 14 * 24 * 3600
    nonisolated static let profileWarning: TimeInterval = 48 * 3600

    /// `ipnstate.PeerStatus.KeyExpiry` (Go's time.Time: RFC 3339, with or
    /// without fractional seconds). Go's zero time (`0001-01-01T00:00:00Z`)
    /// and anything before 1970 mean "no expiry", not "expired" (TailscaleKit's
    /// own `Node` guards the same way).
    nonisolated static func parseKeyExpiry(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty,
              let d = fractionalFormatter.date(from: raw) ?? plainFormatter.date(from: raw),
              d.timeIntervalSince1970 > 0
        else { return nil }
        return d
    }

    // Built once: a dashboard render parses the key expiry. The formatters
    // are thread-safe for parsing and never mutated after this.
    nonisolated(unsafe) private static let fractionalFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let plainFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// `ExpirationDate` from an `embedded.mobileprovision`: a CMS-signed blob
    /// with an XML plist inside it. Nil when there is none (the simulator,
    /// App Store builds) or it cannot be read.
    nonisolated static func profileExpiration(_ data: Data) -> Date? {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex)
        else { return nil }
        let plist = data.subdata(in: start.lowerBound..<end.upperBound)
        guard let dict = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any]
        else { return nil }
        return dict["ExpirationDate"] as? Date
    }

    enum Warning: Equatable {
        case key(expiresIn: TimeInterval)
        case keyExpired
        case profile(expiresIn: TimeInterval)
        case profileExpired
    }

    /// What to warn about now, most urgent (least time left) first.
    nonisolated static func warnings(keyExpiry: Date?, profileExpiry: Date?, now: Date) -> [Warning] {
        var out: [(left: TimeInterval, warning: Warning)] = []
        if let p = profileExpiry {
            let left = p.timeIntervalSince(now)
            if left <= 0 { out.append((left, .profileExpired)) } else if left <= profileWarning { out.append((left, .profile(expiresIn: left))) }
        }
        if let k = keyExpiry {
            let left = k.timeIntervalSince(now)
            if left <= 0 { out.append((left, .keyExpired)) } else if left <= keyWarning { out.append((left, .key(expiresIn: left))) }
        }
        return out.sorted { $0.left < $1.left }.map(\.warning)
    }

    /// Whether a warning is about something still ahead: the dashboard shows
    /// only those. An expired key already has its own banner (Login), and an
    /// expired profile never gets this far.
    nonisolated static func isAhead(_ w: Warning) -> Bool {
        switch w {
        case .key, .profile: return true
        case .keyExpired, .profileExpired: return false
        }
    }

    /// "3 days", "5 hours", "under an hour".
    nonisolated static func describe(_ interval: TimeInterval) -> String {
        if interval >= 2 * 86400 { return "\(Int(interval / 86400)) days" }
        if interval >= 2 * 3600 { return "\(Int(interval / 3600)) hours" }
        if interval >= 3600 { return "an hour" }
        return "under an hour"
    }

    nonisolated static func message(_ w: Warning) -> String {
        switch w {
        case .key(let left):
            return "Your Tailscale key expires in \(describe(left)). To avoid an interruption, disable key expiry for this device in the Tailscale admin console; otherwise, sign in again when it expires."
        case .keyExpired:
            return "Your Tailscale key has expired. Sign in again to reconnect."
        case .profile(let left):
            return "This build of Latchkey stops launching in \(describe(left)). Rebuild and install it from Xcode on your Mac."
        case .profileExpired:
            return "This build's provisioning profile has expired. Rebuild and install it from Xcode."
        }
    }
}
