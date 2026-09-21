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
//  12 probes at a time, 1.5 s per request, 5 s for the whole sweep; results
//  stream into `gateways` as they arrive. HTTPS only (R26): a plain-http
//  origin fails KiroCrew's /api/ws origin check, and HSTS upgrades it anyway.
//  If every probe fails the way a dead proxy fails (-1000 / -1004), that is
//  reported as `proxyUnhealthy` — not "no gateways" — and the node's status
//  is refreshed.
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

    nonisolated static let requestTimeout: TimeInterval = 1.5
    static let deadline: Duration = .seconds(5)
    static let concurrency = 12

    private let model: TSNetModel
    private let refreshStatus: () async -> Void
    private var run: Task<Void, Never>?

    init(model: TSNetModel, refreshStatus: @escaping () async -> Void) {
        self.model = model
        self.refreshStatus = refreshStatus
    }

    /// Starts a sweep, cancelling any in progress.
    func start(savedHost: String?) {
        run?.cancel()
        run = Task { [weak self] in await self?.sweep(savedHost: savedHost) }
    }

    func cancel() {
        run?.cancel()
        run = nil
        if phase == .probing { phase = .finished }
    }

    // MARK: - The sweep

    private enum Outcome: Sendable {
        case gateway(String)
        case notGateway(String)
        case failed(String, code: Int)
        case deadline
    }

    private func sweep(savedHost: String?) async {
        gateways = []
        guard let proxy = model.proxyConfiguration, let status = model.localStatus else {
            logger.log("Discovery: no proxy or status yet; nothing to probe")
            candidateCount = 0
            phase = .finished
            return
        }
        let peers = (status.Peer ?? [:]).values.map(GatewayPeer.init(peer:))
        let candidates = GatewayCandidates.select(peers, selfUserID: status.SelfStatus?.UserID,
                                                  savedHost: savedHost)
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
                if Task.isCancelled { group.cancelAll(); break }
                switch outcome {
                case .deadline:
                    pastDeadline = true
                    if inFlight > 0 {
                        logger.log("Discovery: 5 s deadline with \(inFlight) probe(s) unanswered")
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

        let elapsed = ContinuousClock.now - started
        let proxyDead = !candidates.isEmpty && answered == 0 && !failures.isEmpty
            && failures.allSatisfy { $0 == NSURLErrorBadURL || $0 == NSURLErrorCannotConnectToHost }
        logger.log("Discovery: \(gateways.count) gateway(s); first after \(firstFound.map { "\($0.milliseconds) ms" } ?? "—"), sweep \(elapsed.milliseconds) ms; \(answered) answered, \(failures.count) failed")
        if proxyDead {
            phase = .proxyUnhealthy
            await refreshStatus()
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
        return URLSession(configuration: config)
    }

    nonisolated private static func probe(_ host: String, session: URLSession) async -> Outcome {
        guard let manifestURL = URL(string: "https://\(host)/manifest.json"),
              let authURL = URL(string: "https://\(host)/api/auth/me")
        else { return .notGateway(host) }
        do {
            let (body, response) = try await session.data(from: manifestURL)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
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
                  sharee: peer.ShareeNode ?? false, os: peer.OS, userID: peer.UserID)
    }
}

private extension Duration {
    var milliseconds: Int64 { components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000 }
}
