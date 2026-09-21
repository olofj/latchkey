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
    /// without fractional seconds).
    nonisolated static func parseKeyExpiry(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = fractional.date(from: raw) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }

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

    /// What to warn about now, most urgent first.
    nonisolated static func warnings(keyExpiry: Date?, profileExpiry: Date?, now: Date) -> [Warning] {
        var out: [Warning] = []
        if let p = profileExpiry {
            let left = p.timeIntervalSince(now)
            if left <= 0 { out.append(.profileExpired) } else if left <= profileWarning { out.append(.profile(expiresIn: left)) }
        }
        if let k = keyExpiry {
            let left = k.timeIntervalSince(now)
            if left <= 0 { out.append(.keyExpired) } else if left <= keyWarning { out.append(.key(expiresIn: left)) }
        }
        return out
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
            return "Your Tailscale key expires in \(describe(left)). Sign in again from Settings before then, or renew the key in the admin console."
        case .keyExpired:
            return "Your Tailscale key has expired. Sign in again from Settings."
        case .profile(let left):
            return "This build of Latchkey stops launching in \(describe(left)). Rebuild and install it from Xcode on your Mac."
        case .profileExpired:
            return "This build's provisioning profile has expired. Rebuild and install it from Xcode."
        }
    }
}
