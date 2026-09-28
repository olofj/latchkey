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

/// A gateway is a host and a port (F1 §4.1). The port rides on the origin;
/// 443 is never written, so a 443 gateway reads exactly as it always has.
nonisolated struct GatewayEndpoint: Hashable, Sendable, Identifiable {
    /// tailscale serve's default; a URL with no port means this.
    static let standardPort = 443
    /// The project's standard alternate (R40): serve on 443 takes the port
    /// host-wide on macOS; 8443 is the conventional alt-HTTPS port.
    static let alternatePort = 8443
    /// What discovery probes on every candidate.
    static let standardPorts = [standardPort, alternatePort]

    /// Lowercased FQDN, no trailing dot, never empty.
    let host: String
    /// 1...65535.
    let port: Int

    init?(host: String, port: Int = GatewayEndpoint.standardPort) {
        var h = host.lowercased()
        while h.hasSuffix(".") { h.removeLast() }
        guard !h.isEmpty, (1...65535).contains(port) else { return nil }
        self.host = h
        self.port = port
    }

    /// From `https://host[:port]`; nil for http, a bare name or junk.
    init?(origin: String) {
        guard let parts = URLComponents(string: origin), parts.scheme?.lowercased() == "https",
              let host = parts.host, !host.isEmpty
        else { return nil }
        self.init(host: host, port: parts.port ?? Self.standardPort)
    }

    /// The ports to probe `host` on: the saved gateway's own port first when
    /// it is this host's and not a standard one (F1 §4.2), then the
    /// standard ports, since its owner may have moved it.
    static func ports(for host: String, saved: GatewayEndpoint?) -> [Int] {
        guard let saved, saved.host == GatewayEndpoint(host: host)?.host,
              !standardPorts.contains(saved.port) else { return standardPorts }
        return [saved.port] + standardPorts
    }

    var id: String { "\(host):\(port)" }
    /// `https://host` for 443, `https://host:port` otherwise.
    var origin: String { "https://\(displayName)" }
    /// `host` for 443, `host:port` otherwise: rows, the sign-in sheet, logs.
    var displayName: String { port == Self.standardPort ? host : "\(host):\(port)" }
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

    /// A peer that was not probed, and why (F7 §4.4).
    struct Skipped: Equatable, Sendable {
        let host: String
        /// `exclusion`'s own words, shown to the owner verbatim.
        let reason: String
    }

    /// The peers to probe, in order: the saved gateway first (if it is a
    /// peer at all, whatever the filters say), then the rest alphabetically.
    static func select(_ peers: [GatewayPeer], selfUserID: Int64?, savedHost: String?) -> [GatewayPeer] {
        selectWithSkipped(peers, selfUserID: selfUserID, savedHost: savedHost).probe
    }

    /// `select`, and the peers it declined with the reason each was declined.
    ///
    /// The reasons already existed — `exclusion` returns a string — and were
    /// thrown away, so a gateway filtered out for its owner or its OS simply
    /// vanished and the picker said nothing had answered. On this author's
    /// tailnet that cannot misfire (his gateways are his own or tagged, running
    /// Linux and macOS); on a shared tailnet, or a gateway on a NAS, it hides
    /// the thing the owner is looking for (F7 §1.1).
    ///
    /// **Offline and key-expired peers are deliberately not reported.** They
    /// cannot answer, so offering them would bury the two reasons worth acting
    /// on under a list of sleeping laptops.
    static func selectWithSkipped(_ peers: [GatewayPeer], selfUserID: Int64?,
                                  savedHost: String?) -> (probe: [GatewayPeer], skipped: [Skipped]) {
        var seen = Set<String>()
        let saved = savedHost.map { GatewayPeer(host: $0, online: true, os: nil, userID: nil).host }
        var first: [GatewayPeer] = []
        var rest: [GatewayPeer] = []
        var skipped: [Skipped] = []
        for p in peers where !p.host.isEmpty && seen.insert(p.host).inserted {
            if p.host == saved {
                first.append(p)
            } else if let reason = exclusion(p, selfUserID: selfUserID) {
                if Self.reportableExclusions.contains(reason) || reason.hasPrefix("OS ") {
                    skipped.append(Skipped(host: p.host, reason: reason))
                }
            } else {
                rest.append(p)
            }
        }
        return (first + rest.sorted { $0.host < $1.host },
                skipped.sorted { $0.host < $1.host })
    }

    /// Exclusions worth showing the owner: the ones where the peer could have
    /// answered and a filter decided otherwise. `exclusion`'s OS reason carries
    /// the OS name, so it is matched by prefix.
    /// F7 §4.4 also lists "no MagicDNS name", but that reason is unreachable
    /// here: the loop above drops an empty host before `exclusion` is asked, and
    /// a peer with no name is nothing the owner could tap anyway.
    private static let reportableExclusions: Set<String> = [
        "a node of someone this tailnet shares with", "another owner",
    ]

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

    // MARK: - The origin check (F1 §4a B)

    enum OriginCheck: Equatable, Sendable {
        case unknown, accepted, refused
    }

    /// A credential-less `POST /api/auth/refresh` from the page: 401 (no
    /// refresh cookie) or 429 (the shared rate bucket) got past the CSRF
    /// barrier, so the origin is accepted; 403 is the barrier refusing it.
    /// Anything else, or no answer, decides nothing.
    nonisolated static func originCheck(status: Int?) -> OriginCheck {
        switch status {
        case 401, 429: return .accepted
        case 403: return .refused
        default: return .unknown
        }
    }

    /// What the owner reads when the gateway refuses `origin` (F1 §2).
    static func originRefusedText(origin: String) -> String {
        "This gateway refuses the origin \(origin). It will load but not work: no live updates, "
            + "and sign-in will not last. On the gateway, set KIROCREW_CORS_ORIGINS=\(origin) and restart it, "
            + "or serve on 443."
    }

    // MARK: - Manual entry (M5.3)

    /// Why a typed gateway was refused; `message` is what the owner reads.
    enum ManualEntryRefusal: Error, Equatable, Sendable {
        /// Nothing, or not a host name (spaces, unparseable).
        case notAHost
        /// A port that is not a number in 1...65535, or a bare trailing
        /// colon (F1 §2).
        case badPort
        /// The split-tunnel rule set has no peer data yet, so nothing can be
        /// checked -- and so nothing is accepted.
        case tailnetNotReady
        /// No rule carries `host`: it would load direct.
        case offTailnet(host: String)

        var message: String {
            switch self {
            case .notAHost:
                return "Enter the name of a computer on your tailnet, like gateway or gateway.<tailnet>.ts.net."
            case .badPort:
                return "Enter a host, or host:port (1–65535)."
            case .tailnetNotReady:
                return "The tailnet's peer list hasn't arrived yet, so this name can't be checked. Try again in a moment."
            case .offTailnet(let host):
                return "\(host) isn't on your tailnet. Enter the name of a computer on it, like gateway or gateway.<tailnet>.ts.net."
            }
        }
    }

    /// THE gate for a gateway the owner typed, whichever field it was typed
    /// into: the picker's manual entry, Settings → Gateway, and any field
    /// added later. Returns `https://<host>[:<port>]` only when `policy` -- the live
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
        let host: String, port: Int?
        switch manualHost(raw, suffix: suffix) {
        case .success(let parsed): (host, port) = parsed
        case .failure(let refusal): return .failure(refusal)
        }
        guard let policy, policy.hasPeerData else { return .failure(.tailnetNotReady) }
        guard policy.matchingRule(for: host) != nil else { return .failure(.offTailnet(host: host)) }
        guard let endpoint = GatewayEndpoint(host: host, port: port ?? GatewayEndpoint.standardPort)
        else { return .failure(.notAHost) }
        return .success(endpoint.origin)
    }

    /// Whether `raw` could name a gateway at all -- for enabling a button.
    /// No promise about the tailnet: `manualGateway` decides that.
    static func isPlausibleGatewayName(_ raw: String, suffix: String?) -> Bool {
        if case .success = manualHost(raw, suffix: suffix) { return true }
        return false
    }

    /// The host and port from what the user typed: a bare name is qualified
    /// with the tailnet's MagicDNS suffix, any scheme, path or query is
    /// dropped (the scheme is always https, R26). The port is kept unless it
    /// is 443, which is the origin's default and so never written (F1 §2).
    /// Private on purpose: an origin for the app to load comes only from
    /// `manualGateway`, checked.
    private static func manualHost(_ raw: String, suffix: String?) -> Result<(String, Int?), ManualEntryRefusal> {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure(.notAHost) }
        if let range = text.range(of: "://") { text = String(text[range.upperBound...]) }
        var hostText = text.split(separator: "/", maxSplits: 1).first.map(String.init) ?? text
        // The port is parsed here rather than by URLComponents, which drops
        // a bare trailing colon and takes any Int: both must be refused.
        var port: Int?
        if let colon = hostText.lastIndex(of: ":"),
           !hostText[colon...].contains("]") {
            let digits = hostText[hostText.index(after: colon)...]
            guard !digits.isEmpty, digits.count <= 5, digits.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = Int(digits), (1...65535).contains(value)
            else { return .failure(.badPort) }
            port = value == 443 ? nil : value
            hostText = String(hostText[..<colon])
        }
        guard var host = URLComponents(string: "https://\(hostText)")?.host?.lowercased(),
              !host.isEmpty, !host.contains(" ")
        else { return .failure(.notAHost) }
        while host.hasSuffix(".") { host.removeLast() }
        if !host.contains("."), let suffix, !suffix.isEmpty {
            host += "." + suffix.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        }
        return .success((host, port))
    }
}
