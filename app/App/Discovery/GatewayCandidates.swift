// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

//
//  GatewayCandidates.swift
//  Latchkey
//
//  Which tailnet peers are worth probing for a KiroCrew gateway, and how to
//  tell a gateway when one answers (PLAN M5.1/5.2, revision R26) -- and the
//  one gate a gateway the owner TYPED passes through (`manualGateway`), from
//  whichever field. No TailscaleKit: scripts/test-gateway-candidates.sh
//  compiles it on the host with the real TailnetProxyPolicy and the proxy
//  tests' stubs. `GatewayPeer.init(peer:)` (GatewayDiscovery.swift) is the
//  only bridge from the node's status.
//
//  R26's filters, and why:
//   - Online, not Expired: an offline node cannot answer, and a probe to it
//     only burns the deadline.
//   - Not a ShareeNode: a node owned by someone this tailnet shared a device
//     TO, which may connect to us; not Olof's, and hidden by Tailscale's own
//     UI too (ipnstate.go:313-316).
//   - OS linux / macOS / windows: gateways run on computers. Phones and
//     tablets are the bulk of a personal tailnet's peers.
//   - Same owner as this node -- unless the peer is tagged. A tagged server
//     is owned by the tailnet, not a user, and reports the tagged-devices
//     user; a tagged gateway must not be filtered out (M5 review).
//  The saved gateway is always probed, and first.
//

import Foundation

struct GatewayPeer: Equatable, Sendable {
    /// The MagicDNS FQDN, lowercased, without the trailing dot.
    let host: String
    let online: Bool
    let expired: Bool
    let sharee: Bool
    /// As Tailscale reports it ("linux", "macOS", ...), or nil if unknown.
    let os: String?
    let userID: Int64?
    let tagged: Bool

    init(host: String, online: Bool, expired: Bool = false, sharee: Bool = false,
         os: String?, userID: Int64?, tagged: Bool = false) {
        var h = host.lowercased()
        while h.hasSuffix(".") { h.removeLast() }
        self.host = h
        self.online = online
        self.expired = expired
        self.sharee = sharee
        self.os = os
        self.userID = userID
        self.tagged = tagged
    }
}

enum GatewayCandidates {
    static let serverOSes: Set<String> = ["linux", "macos", "windows"]

    /// Why `peer` is not worth probing, or nil if it is. An unknown OS or
    /// owner does not exclude: a missing field is not evidence of a phone.
    /// "Unknown" arrives as "" and 0, not as absent: Go's ipnstate.PeerStatus
    /// has no omitempty on OS or UserID (M5 review).
    static func exclusion(_ peer: GatewayPeer, selfUserID: Int64?) -> String? {
        if peer.host.isEmpty { return "no MagicDNS name" }
        if !peer.online { return "offline" }
        if peer.expired { return "key expired" }
        if peer.sharee { return "a node of someone this tailnet shares with" }
        if let os = peer.os, !os.isEmpty, !serverOSes.contains(os.lowercased()) { return "OS \(os)" }
        if !peer.tagged, let mine = selfUserID, mine != 0, let theirs = peer.userID, theirs != 0, mine != theirs {
            return "another owner"
        }
        return nil
    }

    /// The peers to probe, in order: the saved gateway first (if it is a
    /// peer at all, whatever the filters say), then the rest alphabetically.
    static func select(_ peers: [GatewayPeer], selfUserID: Int64?, savedHost: String?) -> [GatewayPeer] {
        var seen = Set<String>()
        let saved = savedHost.map { GatewayPeer(host: $0, online: true, os: nil, userID: nil).host }
        var first: [GatewayPeer] = []
        var rest: [GatewayPeer] = []
        for p in peers where !p.host.isEmpty && seen.insert(p.host).inserted {
            if p.host == saved {
                first.append(p)
            } else if exclusion(p, selfUserID: selfUserID) == nil {
                rest.append(p)
            }
        }
        return first + rest.sorted { $0.host < $1.host }
    }

    // MARK: - The fingerprint (R26)

    /// A KiroCrew gateway serves a web app manifest named "Kiro Crew" without
    /// authentication.
    nonisolated static func manifestIsKiroCrew(status: Int, body: Data) -> Bool {
        guard status == 200,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let name = json["name"] as? String
        else { return false }
        return name == "Kiro Crew"
    }

    /// ...and answers an unauthenticated `/api/auth/me` with 403 plus
    /// `X-Auth-Required: true` — the pair every KiroCrew denial carries. A
    /// look-alike manifest alone is not enough.
    nonisolated static func authProbeIsKiroCrew(status: Int, authRequiredHeader: String?) -> Bool {
        status == 403 && authRequiredHeader?.lowercased() == "true"
    }

    // MARK: - Manual entry (M5.3)

    /// Why a typed gateway was refused; `message` is what the owner reads.
    enum ManualEntryRefusal: Error, Equatable, Sendable {
        /// Nothing, or not a host name (spaces, unparseable).
        case notAHost
        /// The split-tunnel rule set has no peer data yet, so nothing can be
        /// checked -- and so nothing is accepted.
        case tailnetNotReady
        /// No rule carries `host`: it would load direct.
        case offTailnet(host: String)

        var message: String {
            switch self {
            case .notAHost:
                return "Enter the name of a computer on your tailnet, like gateway or gateway.<tailnet>.ts.net."
            case .tailnetNotReady:
                return "The tailnet's peer list hasn't arrived yet, so this name can't be checked. Try again in a moment."
            case .offTailnet(let host):
                return "\(host) isn't on your tailnet. Enter the name of a computer on it, like gateway or gateway.<tailnet>.ts.net."
            }
        }
    }

    /// THE gate for a gateway the owner typed, whichever field it was typed
    /// into: the picker's manual entry, Settings → Gateway, and any field
    /// added later. Returns `https://<host>` only when `policy` -- the live
    /// split-tunnel rule set -- carries `host`. Anything else would load
    /// direct, off the tailnet, and become the sign-in origin a pasted token
    /// is sent to (M5 review). The picker had this check and Settings did
    /// not; now neither can have it alone, because the normaliser that
    /// builds the origin is private to this gate.
    ///
    /// Fails closed: the rule is checked against the very host the origin is
    /// built from (no re-parse that could come back nil and skip it), and
    /// with no policy, or one without peer data yet, nothing is accepted.
    static func manualGateway(_ raw: String, suffix: String?,
                              policy: TailnetProxyPolicy?) -> Result<String, ManualEntryRefusal> {
        guard let host = manualHost(raw, suffix: suffix) else { return .failure(.notAHost) }
        guard let policy, policy.hasPeerData else { return .failure(.tailnetNotReady) }
        guard policy.matchingRule(for: host) != nil else { return .failure(.offTailnet(host: host)) }
        return .success("https://\(host)")
    }

    /// Whether `raw` could name a gateway at all -- for enabling a button.
    /// No promise about the tailnet: `manualGateway` decides that.
    static func isPlausibleGatewayName(_ raw: String, suffix: String?) -> Bool {
        manualHost(raw, suffix: suffix) != nil
    }

    /// The host from what the user typed: a bare name is qualified with the
    /// tailnet's MagicDNS suffix, any scheme, port, path or query is dropped
    /// (the scheme is always https, R26). Private on purpose: an origin for
    /// the app to load comes only from `manualGateway`, checked.
    private static func manualHost(_ raw: String, suffix: String?) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let range = text.range(of: "://") { text = String(text[range.upperBound...]) }
        let hostPort = text.split(separator: "/", maxSplits: 1).first.map(String.init) ?? text
        guard var host = URLComponents(string: "https://\(hostPort)")?.host?.lowercased(),
              !host.isEmpty, !host.contains(" ")
        else { return nil }
        while host.hasSuffix(".") { host.removeLast() }
        if !host.contains("."), let suffix, !suffix.isEmpty {
            host += "." + suffix.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        }
        return host
    }
}
