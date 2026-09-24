// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

//
//  SocksRelayPolicy.swift
//  Latchkey
//
//  The two decisions `SocksLogProxy` needs made for it (revision R30).
//
//  The relay is in the data path by default: every proxied connection WebKit
//  opens is a session here, two sockets and a few buffers. Nothing bounded
//  that. A page in a reconnect loop, or sockets iOS defuncted during a
//  suspension and never reports on again, could grow the set without limit.
//  `SocksRelayCapacity` caps it. At the cap the longest-quiet session goes
//  first, provided it has been quiet for `idleGrace`: that is what a
//  defuncted socket looks like, and a pooled connection WebKit is not using
//  loses nothing by being closed (it opens another). Only when every session
//  is live is the newcomer refused. That is a storm, and refusing is the
//  right answer to a storm.
//
//  The relay's own listener can die while tsnet's stays up: iOS may defunct
//  a loopback listener during suspension and leave the NWListener looking
//  alive. tsnet's listener serves LocalAPI as well, so its death is noticed
//  by the status poll and repaired by `recoverLoopbackAfterFailure`, which
//  replaces the relay too. The relay's listener has no poll. What it has is
//  the page: a load that fails on transport (-1000, -1004, -1005) while the
//  node is Running and LocalAPI answers, without the relay having accepted a
//  connection for it, was a load that could not reach the relay.
//  `SocksRelayRecovery` turns that evidence into a verdict. The relay having
//  accepted the request means the failure lies beyond it (a dead gateway is
//  tsnet's reply 4 or 5, which WebKit also reports as -1000; the relay's log
//  line says which), and a new listener would change nothing.
//
//  The evidence above is inference, and it can be wrong both ways (R30
//  review): a pooled connection WebKit reused never reaches the accept log,
//  and a failure that never dialed the proxy looks like one that could not.
//  So the last word is a self-probe -- a loopback TCP connect to the relay's
//  own port (`SocksLogProxy.probe`). Only a listener that refuses it, or
//  does not answer, is restarted. The same probe runs unprompted where the
//  page cannot report: on return to the foreground, and when the dashboard
//  session check gets no answer twice; a page's WebSocket reconnects and its
//  own fetches fail at the dead port without a main-frame navigation ever
//  failing. It gathers evidence, and only a failed probe restarts anything;
//  the foreground itself rebuilds nothing (PLAN M6.1).
//
//  Pure Foundation, so `scripts/test-socks-relay-policy.sh` compiles it
//  alone. `nonisolated`: the relay runs on its own queue, not the main actor.
//

import Foundation

/// How many sessions the relay carries at once, and who goes at the cap.
nonisolated struct SocksRelayCapacity: Sendable {
    /// A dashboard page keeps a handful of connections (WebKit's per-host
    /// pool, the WebSocket, an event stream) and a discovery sweep adds up to
    /// twelve short-lived ones (R26). 64 is far above normal use and far
    /// below a runaway.
    let maxSessions: Int
    /// How long a session must have been silent to be evicted at the cap. A
    /// WebSocket pings well inside a minute; a defuncted socket never speaks.
    let idleGrace: TimeInterval

    init(maxSessions: Int = 64, idleGrace: TimeInterval = 60) {
        self.maxSessions = maxSessions
        self.idleGrace = idleGrace
    }

    nonisolated struct Session: Equatable, Sendable {
        let id: UInt64
        /// The last byte in either direction, or the accept.
        let lastActivity: Date
    }

    nonisolated enum Admission: Equatable, Sendable {
        case accept
        /// Accept, after closing this session, silent for this long.
        case acceptEvicting(id: UInt64, idle: TimeInterval)
        case refuse
    }

    /// Whether a new client may be relayed alongside `active`.
    nonisolated func admit(_ active: [Session], now: Date) -> Admission {
        guard active.count >= maxSessions else { return .accept }
        guard let quietest = active.min(by: { $0.lastActivity < $1.lastActivity }) else {
            return .refuse
        }
        let idle = now.timeIntervalSince(quietest.lastActivity)
        guard idle >= idleGrace else { return .refuse }
        return .acceptEvicting(id: quietest.id, idle: idle)
    }
}

/// The relay's record of a CONNECT tsnet refused (F4 §4.5): what it logs at
/// `SocksLogProxy`'s "FAILED … could not connect" line, published on
/// `TSNetModel.lastProxyFailure` so the page can say WHY a load failed.
/// WebKit collapses every SOCKS reply code into -1000, so this is the only
/// place the difference between "refused", "unreachable" and "no answer at
/// all" survives. Only failures are recorded; the value stays in memory.
///
/// Here, not in `TSNetModel.swift` as F4 §4.5 first placed it, because the
/// relay (`test-socks-relay-policy.sh`), the view model
/// (`test-browser-view-model.sh`) and the wording (`test-page-failure-text.sh`)
/// are all compiled on the host, and this file is the one all three already
/// include. The field itself is on the model, as specified.
nonisolated struct ProxyReply: Sendable, Equatable {
    /// `host:port` exactly as WebKit asked for it.
    let target: String
    /// RFC 1928's name for the reply code: "general failure", "connection
    /// refused", "host unreachable", "network unreachable", …
    let reply: String
    /// From the CONNECT reaching the relay to the reply.
    let elapsed: Duration
    let at: Date

    nonisolated init(target: String, reply: String, elapsed: Duration, at: Date) {
        self.target = target
        self.reply = reply
        self.elapsed = elapsed
        self.at = at
    }

    /// Whether this reply is the one for a load of `fqdn:port` that began at
    /// `navigationStartedAt`. Host names compare case-insensitively: the
    /// qualifier lowercases what the app loads, and WebKit sends what it was
    /// given.
    nonisolated func matches(fqdn: String, port: Int, navigationStartedAt: Date) -> Bool {
        target.caseInsensitiveCompare("\(fqdn):\(port)") == .orderedSame
            && at >= navigationStartedAt
    }
}

/// Whether a failed page load calls for a new relay listener.
nonisolated enum SocksRelayRecovery {
    /// What WebKit reports when the transport under a load breaks. -1000 is
    /// every SOCKS failure reply (measured; `TailnetProxyPolicy.swift`),
    /// -1004 a connect to the proxy that was refused, -1005 a connection that
    /// died under the request. A timeout is left out: a slow gateway is not a
    /// dead listener, and the relay's log shows a CONNECT for it.
    nonisolated static let transportFailureCodes: Set<Int> = [
        NSURLErrorBadURL, NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost,
    ]

    nonisolated static func isTransportFailure(domain: String, code: Int) -> Bool {
        domain == NSURLErrorDomain && transportFailureCodes.contains(code)
    }

    nonisolated static func isTransportFailure(_ error: Error) -> Bool {
        let ns = error as NSError
        return isTransportFailure(domain: ns.domain, code: ns.code)
    }

    /// What the page reports when a load fails.
    nonisolated struct PageFailure: Sendable {
        let domain: String
        let code: Int
        /// When the navigation began. The relay is asked whether it accepted
        /// anything since.
        let navigationStartedAt: Date
    }

    /// What a loopback TCP connect to the relay's own port found.
    nonisolated enum ListenerProbe: String, Equatable, Sendable {
        /// The connect completed: something accepts on that port.
        case answers
        /// Refused outright (nothing listens there any more).
        case refused = "refused"
        /// Neither accepted nor refused within the probe's timeout.
        case timedOut = "did not answer"
    }

    /// Everything the verdict rests on, gathered by the manager.
    nonisolated struct Evidence: Sendable {
        let failure: PageFailure
        /// WebKit is pointed at the relay (not at tsnet directly, as with
        /// `-NoSocksLog` or after a listener that never started).
        let relayInUse: Bool
        let nodeRunning: Bool
        /// `recoverLoopbackAfterFailure` is already replacing the relay.
        let loopbackRecoveryInFlight: Bool
        /// LocalAPI answered over tsnet's loopback listener just now.
        let upstreamAnswers: Bool
        /// The relay accepted a client at or after the navigation began.
        let relayAcceptedSinceNavigation: Bool
        /// The self-probe's finding, once it has run. Nil before: `decide`
        /// then answers `.probe` when everything else points at the
        /// listener, and the manager comes back with `probed(_:)`.
        let listener: ListenerProbe?

        nonisolated init(failure: PageFailure, relayInUse: Bool, nodeRunning: Bool,
                         loopbackRecoveryInFlight: Bool, upstreamAnswers: Bool,
                         relayAcceptedSinceNavigation: Bool, listener: ListenerProbe? = nil) {
            self.failure = failure
            self.relayInUse = relayInUse
            self.nodeRunning = nodeRunning
            self.loopbackRecoveryInFlight = loopbackRecoveryInFlight
            self.upstreamAnswers = upstreamAnswers
            self.relayAcceptedSinceNavigation = relayAcceptedSinceNavigation
            self.listener = listener
        }

        /// The same evidence with the probe's finding added.
        nonisolated func probed(_ outcome: ListenerProbe) -> Evidence {
            Evidence(failure: failure, relayInUse: relayInUse, nodeRunning: nodeRunning,
                     loopbackRecoveryInFlight: loopbackRecoveryInFlight,
                     upstreamAnswers: upstreamAnswers,
                     relayAcceptedSinceNavigation: relayAcceptedSinceNavigation,
                     listener: outcome)
        }
    }

    nonisolated enum Verdict: Equatable, Sendable {
        case restart
        case leave(String)
        /// Everything short of the probe says restart: run it, then decide
        /// again with `Evidence.probed(_:)`.
        case probe
    }

    nonisolated static func decide(_ e: Evidence) -> Verdict {
        guard e.relayInUse else { return .leave("the relay is not in use") }
        guard isTransportFailure(domain: e.failure.domain, code: e.failure.code) else {
            return .leave("\(e.failure.domain) \(e.failure.code) is not a transport failure")
        }
        guard e.nodeRunning else { return .leave("the node is not Running") }
        guard !e.loopbackRecoveryInFlight else { return .leave("loopback recovery is in flight") }
        guard e.upstreamAnswers else { return .leave("tsnet's loopback is not answering; that is loopback recovery's") }
        guard !e.relayAcceptedSinceNavigation else {
            return .leave("the relay accepted the request; the failure lies beyond it")
        }
        guard let listener = e.listener else { return .probe }
        return decide(probe: listener)
    }

    /// The verdict on a probe alone: the unprompted probes (foreground, an
    /// unanswered session check) have no page failure to weigh.
    nonisolated static func decide(probe outcome: ListenerProbe) -> Verdict {
        switch outcome {
        case .answers: return .leave("the listener answers")
        case .refused, .timedOut: return .restart
        }
    }

    /// Restarts allowed within `window`. Each one republishes the proxy
    /// configuration (R27 keeps that rare), and a page that fails for a reason
    /// the verdict cannot see must not keep it churning.
    nonisolated struct Budget: Sendable {
        let maxRestarts: Int
        let window: TimeInterval
        private(set) var recent: [Date] = []

        init(maxRestarts: Int = 2, window: TimeInterval = 60) {
            self.maxRestarts = maxRestarts
            self.window = window
        }

        /// Records a restart at `now` and says whether to go ahead.
        nonisolated mutating func allow(now: Date) -> Bool {
            recent.removeAll { now.timeIntervalSince($0) >= window }
            guard recent.count < maxRestarts else { return false }
            recent.append(now)
            return true
        }
    }
}
