// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

//
//  GatewayDiscovery.swift
//  Latchkey
//
//  Finds KiroCrew gateways among the tailnet's peers (PLAN M5, revision R26).
//
//  Peers come from the node's status (`tsnetModel.localStatus`, R18) and are
//  filtered and ordered by `GatewayCandidates`: the saved gateway first. Each
//  candidate is probed over HTTPS through the node's own proxy — an ephemeral
//  `URLSession` built from the published `proxyConfiguration`, so a probe
//  takes exactly the path the dashboard will — and counts as a gateway only if
//  BOTH hold:
//    - `GET /manifest.json` is JSON named "Kiro Crew", and
//    - `GET /api/auth/me` (no cookies) is 403 with `X-Auth-Required: true`.
//
//  12 probes at a time, 4 s per request, 12 s for the whole sweep; results
//  stream into `gateways` as they arrive. HTTPS only (R26): a plain-http
//  origin fails KiroCrew's /api/ws origin check, and HSTS upgrades it anyway.
//  Redirects are never followed: the probe session has no route for a host
//  outside the tailnet, and a gateway does not redirect its manifest (M5
//  review). Only hosts the published proxy policy routes are probed.
//  If no probe gets an answer, the node's loopback (which serves both the
//  SOCKS5 proxy and LocalAPI, R18) is asked directly: silent there means
//  `proxyUnhealthy`; alive means nothing answered. Error codes cannot tell
//  the two apart -- -1000 is every SOCKS failure reply (M5 review).
//

import Combine
import Foundation
import Network
import TailscaleKit

@MainActor
final class GatewayDiscovery: ObservableObject {
    struct Gateway: Identifiable, Equatable, Sendable {
        let host: String
        var id: String { host }
        var url: String { "https://\(host)" }
    }

    enum Phase: Equatable {
        case idle
        case probing
        case finished
        /// Every probe failed as if the proxy were down.
        case proxyUnhealthy
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var gateways: [Gateway] = []
    @Published private(set) var candidateCount = 0

    /// Per-request budget. Was 1.5 s, chosen before anyone had tried a real
    /// tailnet: on the first device run (2026-09-23) the phone's network
    /// blocked UDP, so every path relayed through DERP over TCP, and the
    /// gateway was a continent away (190 ms RTT direct, more relayed). A
    /// probe is TCP, then TLS, then the request, and the peer's WireGuard
    /// handshake may happen inside it; 1.5 s loses that race against a
    /// gateway that would have answered. 4 s covers a relayed
    /// intercontinental path with room to spare, and a dead peer still costs
    /// only one probe's wait because they run concurrently.
    nonisolated static let requestTimeout: TimeInterval = 4
    /// Whole-sweep budget: enough for two rounds of `concurrency` probes at
    /// the per-request timeout, so a slow peer cannot starve a later one.
    static let deadline: Duration = .seconds(12)
    static let concurrency = 12

    private let model: TSNetModel
    /// Asks the node's loopback for its status; true if it answered.
    private let loopbackAnswers: () async -> Bool
    private var run: Task<Void, Never>?
    /// Bumped by every start(): a superseded sweep must not write its result
    /// over a newer one's (M5 review).
    private var generation = 0

    init(model: TSNetModel, loopbackAnswers: @escaping () async -> Bool) {
        self.model = model
        self.loopbackAnswers = loopbackAnswers
    }

    /// When the picker appeared: R26's clock starts there, not when the
    /// sweep does -- a wait for the node's status before it is part of what
    /// the user waits for (M5 review).
    private var shownAt: ContinuousClock.Instant?

    /// Starts a sweep, cancelling any in progress. `shownAt` is when the
    /// picker appeared, if a picker is waiting for this.
    func start(savedHost: String?, shownAt: ContinuousClock.Instant? = nil) {
        run?.cancel()
        generation += 1
        let mine = generation
        self.shownAt = shownAt
        run = Task { [weak self] in await self?.sweep(savedHost: savedHost, generation: mine) }
    }

    func cancel() {
        run?.cancel()
        run = nil
        generation += 1
        if phase == .probing { phase = .idle }
    }

    // MARK: - The sweep

    private enum Outcome: Sendable {
        case gateway(String)
        case notGateway(String)
        case failed(String, code: Int)
        case deadline
    }

    private func sweep(savedHost: String?, generation mine: Int) async {
        gateways = []
        guard let proxy = model.proxyConfiguration, let status = model.localStatus else {
            logger.log("Discovery: no proxy or status yet; nothing to probe")
            candidateCount = 0
            phase = .finished
            return
        }
        let peers = (status.Peer ?? [:]).values.map(GatewayPeer.init(peer:))
        // Never probe a host the proxy would not carry: its probe would go
        // direct, off the tailnet (M5 review). The policy covers every peer
        // name, so this only ever drops a malformed one.
        let policy = model.proxyPolicy
        let candidates = GatewayCandidates.select(peers, selfUserID: status.SelfStatus?.UserID,
                                                  savedHost: savedHost)
            .filter { policy?.matchingRule(for: $0.host) != nil }
        candidateCount = candidates.count
        phase = .probing
        let started = ContinuousClock.now
        logger.log("Discovery: probing \(candidates.count) of \(peers.count) peer(s)")

        guard !candidates.isEmpty else {
            // Nothing to wait for: do not sit out the deadline.
            logger.log("Discovery: 0 gateway(s); no candidates among \(peers.count) peer(s)")
            phase = .finished
            return
        }
        let session = Self.makeSession(proxy: proxy)
        defer { session.invalidateAndCancel() }
        var failures: [Int] = []
        var answered = 0
        var firstFound: Duration?

        await withTaskGroup(of: Outcome.self) { group in
            var pending = candidates.makeIterator()
            group.addTask {
                try? await Task.sleep(for: Self.deadline)
                return .deadline
            }
            var inFlight = 0
            var pastDeadline = false
            while inFlight < Self.concurrency, let next = pending.next() {
                group.addTask { await Self.probe(next.host, session: session) }
                inFlight += 1
            }
            while let outcome = await group.next() {
                if Task.isCancelled || mine != generation { group.cancelAll(); break }
                switch outcome {
                case .deadline:
                    pastDeadline = true
                    if inFlight > 0 {
                        logger.log("Discovery: \(Self.deadline) deadline with \(inFlight) probe(s) unanswered")
                    }
                    group.cancelAll()
                    continue
                case .gateway(let host):
                    answered += 1
                    if firstFound == nil { firstFound = ContinuousClock.now - started }
                    if !gateways.contains(where: { $0.host == host }) {
                        gateways.append(Gateway(host: host))
                    }
                case .notGateway:
                    answered += 1
                case .failed(_, let code):
                    failures.append(code)
                }
                inFlight -= 1
                if !pastDeadline, !Task.isCancelled, let next = pending.next() {
                    group.addTask { await Self.probe(next.host, session: session) }
                    inFlight += 1
                }
                if inFlight == 0 { group.cancelAll() }
            }
        }

        guard mine == generation, !Task.isCancelled else { return }
        let elapsed = ContinuousClock.now - started
        let fromShown = firstFound.flatMap { first in shownAt.map { (started + first) - $0 } }
        // Nothing answered: ask the loopback itself whether the proxy is up.
        var proxyDead = false
        if answered == 0, !failures.isEmpty {
            proxyDead = !(await loopbackAnswers())
        }
        guard mine == generation else { return }
        logger.log("Discovery: \(gateways.count) gateway(s); first after \(firstFound.map { "\($0.milliseconds) ms" } ?? "—"), sweep \(elapsed.milliseconds) ms; \(answered) answered, \(failures.count) failed; shown to first \(fromShown.map { "\($0.milliseconds) ms" } ?? "—")")
        if proxyDead {
            phase = .proxyUnhealthy
        } else {
            phase = .finished
        }
    }

    // MARK: - One probe

    nonisolated private static func makeSession(proxy: ProxyConfiguration) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.proxyConfigurations = [proxy]
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = requestTimeout * 2
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }

    nonisolated private static func probe(_ host: String, session: URLSession) async -> Outcome {
        guard let manifestURL = URL(string: "https://\(host)/manifest.json"),
              let authURL = URL(string: "https://\(host)/api/auth/me")
        else { return .notGateway(host) }
        do {
            let (body, response) = try await session.data(from: manifestURL)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            // A 3xx arrives unfollowed (NoRedirects): not a gateway.
            guard GatewayCandidates.manifestIsKiroCrew(status: status, body: body) else {
                return .notGateway(host)
            }
            let (_, authResponse) = try await session.data(from: authURL)
            let http = authResponse as? HTTPURLResponse
            return GatewayCandidates.authProbeIsKiroCrew(
                status: http?.statusCode ?? 0,
                authRequiredHeader: http?.value(forHTTPHeaderField: "X-Auth-Required"))
                ? .gateway(host) : .notGateway(host)
        } catch {
            return .failed(host, code: (error as NSError).code)
        }
    }
}

extension GatewayPeer {
    init(peer: IpnState.PeerStatus) {
        self.init(host: peer.DNSName, online: peer.Online, expired: peer.Expired ?? false,
                  sharee: peer.ShareeNode ?? false, os: peer.OS, userID: peer.UserID,
                  tagged: !(peer.Tags ?? []).isEmpty)
    }
}

/// Refuses every redirect: a probe must never be carried to a host outside
/// the tailnet (M5 review). The 3xx itself is returned to the caller.
/// (The completion-handler form: Swift 6.4's SILGen crashed on the async one.)
private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    nonisolated override init() { super.init() }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                                willPerformHTTPRedirection response: HTTPURLResponse,
                                newRequest request: URLRequest,
                                completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private extension Duration {
    var milliseconds: Int64 { components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000 }
}
