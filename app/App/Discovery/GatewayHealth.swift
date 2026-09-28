// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

//
//  GatewayHealth.swift
//  Latchkey
//
//  F22: the lights of the app bar's gateway row. Each remembered gateway is
//  probed directly, on its own port, with discovery's fingerprint and
//  discovery's session (proxy only, no cookies, no redirects): no sweep of
//  the tailnet. It runs only while the row is on screen, so a retracted bar
//  costs nothing, and a verdict younger than `freshFor` is not asked again.
//
//  A light is a forecast, never a gate: a red gateway can still be chosen,
//  and F4 reports the real load (F5 §7's rule).
//

import Combine
import Foundation

@MainActor
final class GatewayHealth: ObservableObject {
    typealias Verdict = GatewayChipState.Verdict

    @Published private(set) var verdicts: [String: Verdict] = [:]

    /// How long a verdict stands before the row asks again.
    static let freshFor: Duration = .seconds(30)

    private let model: TSNetModel
    private var checkedAt: [String: ContinuousClock.Instant] = [:]
    private var inFlight: [String: Task<Void, Never>] = [:]

    init(model: TSNetModel) {
        self.model = model
    }

    /// Probes each of `origins` whose verdict is missing or stale, all at
    /// once. A stale verdict keeps showing until its replacement lands: the
    /// row must not flash amber every 30 s. An origin the tailnet does not
    /// carry is never probed (it would leave the tailnet).
    func refresh(_ origins: [String]) {
        guard let proxy = model.proxyConfiguration, let policy = model.proxyPolicy else { return }
        let now = ContinuousClock.now
        for origin in origins where inFlight[origin] == nil {
            if let at = checkedAt[origin], now - at < Self.freshFor { continue }
            guard let endpoint = GatewayEndpoint(origin: origin),
                  policy.matchingRule(for: endpoint.host) != nil else { continue }
            if verdicts[origin] == nil { verdicts[origin] = .checking }
            // Timed from the asking, not the answer: the row's next pass is
            // `freshFor` after this one, and a verdict timed from its answer
            // is then a few milliseconds short of stale, so every other pass
            // skipped it and the row asked every 60 s.
            checkedAt[origin] = now
            inFlight[origin] = Task { [weak self] in
                let session = GatewayDiscovery.makeSession(proxy: proxy)
                defer { session.invalidateAndCancel() }
                let verdict = await GatewayDiscovery.probe(endpoint.host, port: endpoint.port, session: session)
                guard !Task.isCancelled, let self else { return }
                self.inFlight[origin] = nil
                self.verdicts[origin] = switch verdict {
                case .gateway: .answering
                case .notGateway: .notGateway
                case .failed: .notAnswering
                }
                logger.log("Gateway row: \(endpoint.displayName) \(String(describing: self.verdicts[origin]!))")
            }
        }
    }

    /// The row has gone: nothing is probed for a bar no one can see. A
    /// cancelled probe leaves no verdict time, so the next show asks again.
    func stop() {
        for (origin, task) in inFlight {
            task.cancel()
            checkedAt[origin] = nil
        }
        inFlight = [:]
    }
}
