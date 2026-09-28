// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

//
//  GatewayChipState.swift
//  Latchkey
//
//  F22: what one chip in the app bar's gateway row says. Pure, so the table
//  in F22 §4 is tested on the host (scripts/test-gateway-row.sh).
//
//  The lights are the dashboard's own (its instance bar colours `connected`
//  --ok, `connecting` --warn, `error` --danger, anything else --muted), and
//  mean the same things: the chip in use follows its page's load, the others
//  a probe of their own gateway. As there, a chip that is not green says its
//  state in words, so colour is never the only signal.
//

import Foundation

nonisolated struct GatewayChipState: Equatable, Sendable {
    enum Light: Equatable, Sendable { case ok, warn, danger, muted }

    /// The page's load, for the chip in use: `PageState` folded to what the
    /// light shows.
    enum Load: Equatable, Sendable { case idle, connecting, committed, failed }

    /// A probe of another gateway (`GatewayHealth`).
    enum Verdict: Equatable, Sendable { case checking, answering, notGateway, notAnswering }

    let light: Light
    /// "" when the light says it all: the dashboard shows no word for green.
    let word: String
    /// The chip in use is never a switch; a gateway the tailnet cannot reach
    /// is not either (it would load direct, off the tailnet: F5 §7).
    let tappable: Bool

    static func current(_ load: Load) -> Self {
        switch load {
        case .committed: return .init(light: .ok, word: "connected", tappable: false)
        case .connecting: return .init(light: .warn, word: "connecting", tappable: false)
        case .failed: return .init(light: .danger, word: "failed", tappable: false)
        case .idle: return .init(light: .muted, word: "", tappable: false)
        }
    }

    /// Another gateway. `verdict` nil means not probed yet: it is about to
    /// be, as the row only exists while it is probing.
    static func other(ready: Bool, carried: Bool, verdict: Verdict?) -> Self {
        guard ready else { return .init(light: .muted, word: "tailnet not connected", tappable: false) }
        guard carried else { return .init(light: .muted, word: "not on this tailnet", tappable: false) }
        switch verdict {
        case .answering: return .init(light: .ok, word: "answering", tappable: true)
        case .checking, nil: return .init(light: .warn, word: "checking", tappable: true)
        case .notGateway: return .init(light: .danger, word: "not KiroCrew", tappable: true)
        case .notAnswering: return .init(light: .danger, word: "not answering", tappable: true)
        }
    }

    /// `host` or `host:port` without the scheme: the chip's identifier and
    /// its accessibility label, as Settings' rows name a gateway.
    static func shown(_ origin: String) -> String {
        origin.replacingOccurrences(of: "https://", with: "")
    }

    /// The chip's text: the first DNS label, and the port off 443.
    /// `https://mac-studio.tail1234.ts.net:8443` → `mac-studio:8443`.
    static func shortName(_ origin: String) -> String {
        guard let parts = URLComponents(string: origin), let host = parts.host, !host.isEmpty
        else { return shown(origin) }
        let label = host.split(separator: ".").first.map(String.init) ?? host
        if let port = parts.port, port != 443 { return "\(label):\(port)" }
        return label
    }

    /// The row's chips, in order: the one in use, then the others as the
    /// remembered list has them (most recent first), each once. Empty when
    /// there is nothing to switch to: one chip alone is no row (F22 §2).
    static func order(current: String, known: [String]) -> [String] {
        var seen: Set<String> = [current]
        let others = known.filter { seen.insert($0).inserted }
        guard !current.isEmpty, !others.isEmpty else { return [] }
        return [current] + others
    }
}
