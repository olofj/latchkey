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

    // F7 §4.1. The picker used to report `candidateCount` as the number of
    // computers checked, but the sweep abandons whatever is still pending when
    // the deadline fires (`concurrency` 12 × `requestTimeout` 4 s inside a 12 s
    // budget is about two rounds, so roughly 24 peers). On a large tailnet it
    // therefore claimed to have checked sixty machines when it checked
    // twenty-four. That is the only place the environment difference produced a
    // false statement to the owner rather than a slower result.

    /// How many candidates have returned a verdict — answered, not-a-gateway or
    /// failed — across this chain of sweeps. `probedHosts.count`, republished.
    @Published private(set) var probedCount = 0
    /// Some candidate never produced a verdict, so the list is not exhausted.
    /// **Not** simply "the deadline fired": a deadline that arrives with every
    /// verdict in hand is an ordinary slow sweep, and conflating the two would
    /// cry wolf on every one of them.
    @Published private(set) var sweepTruncated = false
    /// Where the next sweep resumes, so *Search again* can reach the tail of a
    /// large tailnet instead of re-probing the same first two rounds forever.
    @Published private(set) var nextCandidateIndex = 0
    /// Peers a filter declined, with the reason, for the owner to probe anyway.
    @Published private(set) var skipped: [GatewayCandidates.Skipped] = []

    /// Of the probed, how many replied at all — whether or not they turned out
    /// to be a gateway — and how many never replied (F4 §4.8). The split is what
    /// lets the picker tell the two situations apart: peers that answered and
    /// simply are not gateways means the tailnet is fine, and peers that did not
    /// answer at all usually means this device is not allowed to reach them yet,
    /// which is the one case where searching again cannot help.
    @Published private(set) var answeredCount = 0
    @Published private(set) var unansweredCount = 0
    /// When the sweep now running began, so the picker can tick a duration.
    /// Non-nil means "a sweep is in flight"; every exit from `.probing` clears it.
    @Published private(set) var startedAt: ContinuousClock.Instant?
    /// Peers in the netmap, gateway candidates or not. The picker says "0
    /// candidates among 3 peers" (F4 §3.5 P7), which distinguishes "the tailnet
    /// has nothing that could be a gateway" from "the netmap has not arrived".
    @Published private(set) var peerCount = 0
    /// The last finished sweep, for Settings → Gateway → "Last discovery".
    @Published private(set) var lastSweep: SweepSummary?

    struct SweepSummary: Equatable, Sendable {
        let candidates: Int
        let probed: Int
        let answered: Int
        let unanswered: Int
        let gateways: Int
        let truncated: Bool
        let elapsed: Duration
    }

    /// Each candidate's verdict — true if it replied, false if it never did —
    /// keyed by host. Keyed, not counted, because a continuation re-probes the
    /// saved gateway (always the first candidate) and may re-probe a peer that
    /// was in flight when the deadline cancelled it; counting events instead of
    /// hosts would tell the owner it checked 25 of 24 computers. Keeping the
    /// verdict rather than just the host also keeps
    /// `answeredCount + unansweredCount == probedCount` true by construction,
    /// which the picker's wording states as a fact.
    private var verdicts: [String: Bool] = [:]
    /// When the last `Discovery: progress` line was written; at most one a
    /// second, so a 40-peer sweep does not drown the log it is meant to explain.
    private var lastProgressLog: ContinuousClock.Instant?

    /// Records a verdict for `host` and republishes the counts.
    private func recordProbed(_ host: String, replied: Bool) {
        verdicts[host] = replied
        probedCount = verdicts.count
        answeredCount = verdicts.values.filter { $0 }.count
        unansweredCount = verdicts.count - answeredCount
    }

    /// `Discovery: progress k/n at t ms`, at most once a second (F4 §4.8). Its
    /// own line: the two lines `scripts/test-discovery.sh` parses must not gain
    /// or lose a character, which F7 learned by breaking them.
    private func logProgress(started: ContinuousClock.Instant) {
        let now = ContinuousClock.now
        if let last = lastProgressLog, now - last < .seconds(1) { return }
        lastProgressLog = now
        logger.log("Discovery: progress \(probedCount)/\(candidateCount) at \((now - started).milliseconds) ms")
    }

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
    /// - Parameter continueFrom: index into the ordered candidate list to resume
    ///   at (F7 §4.3). *Search again* passes `nextCandidateIndex` after a
    ///   truncated sweep and 0 otherwise; restarting from the top could never
    ///   reach the tail of a large tailnet however many times it was tapped.
    func start(savedHost: String?, shownAt: ContinuousClock.Instant? = nil,
               continueFrom: Int = 0) {
        run?.cancel()
        generation += 1
        let mine = generation
        self.shownAt = shownAt
        run = Task { [weak self] in
            await self?.sweep(savedHost: savedHost, generation: mine, continueFrom: continueFrom)
        }
    }

    func cancel() {
        run?.cancel()
        run = nil
        generation += 1
        if phase == .probing { phase = .idle }
        // `startedAt` means "a sweep is in flight", and the picker ticks a
        // duration from it. Every path out of .probing must clear it or the
        // picker counts up forever over a sweep that is not running.
        startedAt = nil
    }

    /// Probe one peer a filter declined (F7 §4.4). If it answers it joins
    /// `gateways` like any other and leaves the skipped list.
    ///
    /// Nothing is persisted as an exception: choosing it saves it as the
    /// gateway, and a saved gateway is probed first thereafter whatever the
    /// filters say. So one tap is enough, and no "allowed peers" list has to
    /// exist to be maintained or to go stale.
    func probeAnyway(_ host: String) {
        guard let proxy = model.proxyConfiguration else { return }
        // Refuse a host the proxy would not carry: its probe would go direct,
        // off the tailnet, for the same reason the sweep filters them (M5
        // review). A skipped peer came from the netmap, so this only ever
        // drops a malformed name.
        guard model.proxyPolicy?.matchingRule(for: host) != nil else {
            logger.log("Discovery: refusing to probe \(host): the proxy does not carry it")
            return
        }
        let mine = generation
        Task { [weak self] in
            let session = Self.makeSession(proxy: proxy)
            defer { session.invalidateAndCancel() }
            let outcome = await Self.probe(host, session: session)
            guard let self, mine == self.generation else { return }
            // Deliberately NOT counted in `probedCount`: this peer is not one of
            // the candidates `candidateCount` counts, and adding it would have
            // the picker say it checked more computers than it found to check.
            switch outcome {
            case .gateway(let found):
                if !self.gateways.contains(where: { $0.host == found }) {
                    self.gateways.append(Gateway(host: found))
                }
                self.skipped.removeAll { $0.host == found }
                logger.log("Discovery: \(found) answered when probed anyway")
            case .notGateway, .failed, .deadline:
                // Leave it listed, so the owner can see it was tried and that
                // the filter was not what hid a gateway.
                self.skipped = self.skipped.map {
                    $0.host == host ? .init(host: $0.host, reason: "\($0.reason) — tried, no answer") : $0
                }
                logger.log("Discovery: \(host) probed anyway, not a gateway")
            }
        }
    }

    // MARK: - The sweep

    private enum Outcome: Sendable {
        case gateway(String)
        case notGateway(String)
        case failed(String, code: Int)
        case deadline
    }

    private func sweep(savedHost: String?, generation mine: Int, continueFrom: Int = 0) async {
        // A continuation keeps what the chain already established: the gateways
        // an earlier sweep found — they must not vanish from the picker on the
        // tap meant to find *more* — and which candidates already have a
        // verdict, so the count the owner reads climbs toward the total instead
        // of restarting at the resume point (F7 §4.2). Only the explicit
        // "Keep searching" button continues; every other start is fresh, so a
        // gateway listed here was either found seconds ago or re-probed as the
        // saved host, which a continuation always probes first.
        if continueFrom == 0 {
            gateways = []
            verdicts = [:]
            probedCount = 0
            answeredCount = 0
            unansweredCount = 0
        }
        sweepTruncated = false
        nextCandidateIndex = 0
        skipped = []
        lastProgressLog = nil
        startedAt = .now
        guard let proxy = model.proxyConfiguration, let status = model.localStatus else {
            logger.log("Discovery: no proxy or status yet; nothing to probe")
            candidateCount = 0
            startedAt = nil
            phase = .finished
            return
        }
        let peers = (status.Peer ?? [:]).values.map(GatewayPeer.init(peer:))
        peerCount = peers.count
        // Never probe a host the proxy would not carry: its probe would go
        // direct, off the tailnet (M5 review). The policy covers every peer
        // name, so this only ever drops a malformed one.
        let policy = model.proxyPolicy
        let split = GatewayCandidates.selectWithSkipped(peers,
                                                        selfUserID: status.SelfStatus?.UserID,
                                                        savedHost: savedHost)
        let ordered = split.probe.filter { policy?.matchingRule(for: $0.host) != nil }
        skipped = split.skipped.filter { policy?.matchingRule(for: $0.host) != nil }
        // Resume where the last sweep ran out of time, but always keep the
        // saved gateway (element 0, whatever the filters say) at the front: the
        // likeliest reason for searching again is that it came back.
        // Each entry carries its index in `ordered`, so the cursor published for
        // the next sweep means something in the full list rather than in this
        // resumed slice of it.
        let plan: [(peer: GatewayPeer, orderedIndex: Int)]
        if continueFrom > 0, continueFrom < ordered.count {
            plan = ordered.enumerated()
                .filter { $0.offset == 0 || $0.offset >= continueFrom }
                .map { (peer: $0.element, orderedIndex: $0.offset) }
        } else {
            plan = ordered.enumerated().map { (peer: $0.element, orderedIndex: $0.offset) }
        }
        let candidates = plan.map(\.peer)
        // The whole candidate list, not this sweep's slice of it: it is the
        // number of computers that could be a gateway, and the picker divides
        // the probed count by it. A continuation must not shrink the
        // denominator, or "checked 16 of 17" would look like a finished search
        // of a 40-machine tailnet.
        candidateCount = ordered.count
        phase = .probing
        let started = ContinuousClock.now
        // BYTE-FOR-BYTE UNCHANGED, and it must stay that way: this line and the
        // summary below are parsed by scripts/test-discovery.sh (its regexes at
        // :151 and :155-156), and the summary's is anchored with `$`. F7 first
        // rewrote this one and appended its new counters to the summary, which
        // made both regexes miss; the suite's parser then recorded no sweep at
        // all and would have failed with "this measured nothing". New numbers go
        // on their OWN line (F4 §4.8).
        logger.log("Discovery: probing \(candidates.count) of \(peers.count) peer(s)")
        if continueFrom > 0 {
            logger.log("Discovery: continuing at candidate \(continueFrom) of \(ordered.count)")
        }

        guard !candidates.isEmpty else {
            // Nothing to wait for: do not sit out the deadline.
            logger.log("Discovery: 0 gateway(s); no candidates among \(peers.count) peer(s)")
            startedAt = nil
            phase = .finished
            return
        }
        let session = Self.makeSession(proxy: proxy)
        defer { session.invalidateAndCancel() }
        var failures: [Int] = []
        var answered = 0
        var firstFound: Duration?

        await withTaskGroup(of: Outcome.self) { group in
            // An explicit cursor, not an iterator: when the deadline fires the
            // sweep must be able to say whether anything was left undispatched,
            // and where to resume (F7 §4.1, §4.3).
            var cursor = 0
            group.addTask {
                try? await Task.sleep(for: Self.deadline)
                return .deadline
            }
            var inFlight = 0
            var pastDeadline = false
            while inFlight < Self.concurrency, cursor < plan.count {
                let next = plan[cursor].peer
                cursor += 1
                group.addTask { await Self.probe(next.host, session: session) }
                inFlight += 1
            }
            while let outcome = await group.next() {
                if Task.isCancelled || mine != generation { group.cancelAll(); break }
                switch outcome {
                case .deadline:
                    pastDeadline = true
                    if inFlight > 0 || cursor < plan.count {
                        logger.log("Discovery: \(Self.deadline) deadline with \(inFlight) probe(s) unanswered and \(plan.count - cursor) never dispatched")
                    }
                    group.cancelAll()
                    continue
                case .gateway(let host):
                    answered += 1
                    if firstFound == nil { firstFound = ContinuousClock.now - started }
                    if !gateways.contains(where: { $0.host == host }) {
                        gateways.append(Gateway(host: host))
                    }
                    recordProbed(host, replied: true)
                case .notGateway(let host):
                    answered += 1
                    recordProbed(host, replied: true)
                case .failed(let host, let code):
                    failures.append(code)
                    // A probe that got no reply at all. `.failed` is also what a
                    // refusal arrives as, but from the owner's side both mean
                    // "nothing there answered me".
                    recordProbed(host, replied: false)
                }
                logProgress(started: started)
                inFlight -= 1
                if !pastDeadline, !Task.isCancelled, cursor < plan.count {
                    let next = plan[cursor].peer
                    cursor += 1
                    group.addTask { await Self.probe(next.host, session: session) }
                    inFlight += 1
                }
                if inFlight == 0 { group.cancelAll() }
            }
        }

        guard mine == generation, !Task.isCancelled else { return }
        // Truncation is "a candidate has no verdict" — whether it was never
        // dispatched or was still in flight when the deadline cancelled it.
        // Deriving it here rather than from the cursor covers both, and buys the
        // invariant the picker's wording depends on: not truncated means every
        // candidate was probed, so `probedCount == candidateCount` once a chain
        // of sweeps completes.
        //
        // The resume point is the FIRST candidate without a verdict, not where
        // the cursor stopped: a peer that timed out inside the dispatched window
        // is behind the cursor, and resuming past it would strand it for good.
        // Re-probing a few that did answer is the cheap side of that trade.
        if let firstUnprobed = plan.first(where: { verdicts[$0.peer.host] == nil }) {
            sweepTruncated = true
            nextCandidateIndex = firstUnprobed.orderedIndex
        }
        let elapsed = ContinuousClock.now - started
        let fromShown = firstFound.flatMap { first in shownAt.map { (started + first) - $0 } }
        // Nothing answered: ask the loopback itself whether the proxy is up.
        var proxyDead = false
        if answered == 0, !failures.isEmpty {
            proxyDead = !(await loopbackAnswers())
        }
        guard mine == generation else { return }
        logger.log("Discovery: \(gateways.count) gateway(s); first after \(firstFound.map { "\($0.milliseconds) ms" } ?? "—"), sweep \(elapsed.milliseconds) ms; \(answered) answered, \(failures.count) failed; shown to first \(fromShown.map { "\($0.milliseconds) ms" } ?? "—")")
        // F7's counters, on their own line so the summary above stays the
        // instrument scripts/test-discovery.sh parses.
        //
        // Mind the SCOPES: the summary above describes the sweep that just ran
        // — its `answered`/`failed`, like its elapsed time, are that sweep's own
        // — while `probed`/`candidates` here describe the whole chain of
        // continuations, because `probedCount` counts distinct hosts across it.
        // The two therefore agree exactly only when this sweep is not a
        // continuation, which the `continuing at candidate` line above marks.
        // The suite checks that invariant in both forms, so a future change that
        // mixes the scopes will fail rather than quietly mislead.
        logger.log("Discovery: probed=\(probedCount)/\(candidateCount) truncated=\(sweepTruncated ? "yes" : "no") skipped=\(skipped.count)\(sweepTruncated ? " next=\(nextCandidateIndex)" : "")")
        lastSweep = SweepSummary(candidates: candidateCount, probed: probedCount,
                                 answered: answeredCount, unanswered: unansweredCount,
                                 gateways: gateways.count, truncated: sweepTruncated,
                                 elapsed: elapsed)
        // Cleared so the picker's ticking duration cannot keep running over a
        // finished sweep: `startedAt` means "a sweep is in flight".
        startedAt = nil
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
