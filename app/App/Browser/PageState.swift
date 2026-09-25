// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

//
//  PageState.swift
//  Latchkey
//
//  What the dashboard page is doing, as one value (F4 §4.2).
//
//  Before this the page had `isLoading` (read by nothing), `navError` (a
//  tuple), and no notion of "waiting for peers" or "connecting" at all. So a
//  manual entry to a gateway the node could not reach was a blank WKWebView
//  for the full 30 s SOCKS dial (`socks5.go:99`), and a Kiro Crew restart
//  behind `tailscale serve` was an empty 502 committed as the document, for
//  ever. Every state the page can be in now has a case, and every case has
//  words (`PageFailureText`), an identifier (§4.12) and a log line (§4.9).
//
//  Pure Foundation and `nonisolated`, so `scripts/test-page-failure-text.sh`
//  compiles it on the host without the app.
//

import Foundation

nonisolated enum PageState: Equatable {
    case idle
    /// D2: `loadInitial` is waiting for the node's status or peer list before
    /// it can decide where the first load goes. `since` is the first hold.
    case holding(host: String, since: ContinuousClock.Instant)
    /// D4/D5: a main-frame load is in flight and nothing has committed.
    /// `since` is the FIRST attempt's stamp; `attempt` counts the silent
    /// startup retries (`BrowserViewModel.retryStartupLoadIfAppropriate`), so
    /// the clock on screen never restarts while they run.
    case connecting(host: String, port: Int, since: ContinuousClock.Instant, attempt: Int)
    case committed
    /// D6/D7/D9/D10.
    case failed(Failure)

    /// A failed page load, with everything the error page and Settings →
    /// Status need to say what happened.
    ///
    /// Not `SocksRelayRecovery.PageFailure` (`App/Network/SocksRelayPolicy.swift`),
    /// which is the three-field report the page sends the tsnet manager so it
    /// can judge its relay listener (R30). That one goes out; this one is what
    /// the owner reads.
    nonisolated struct Failure: Equatable {
        nonisolated enum Cause: Equatable {
            /// SOCKS general failure after a long dial: dropped SYNs, i.e. the
            /// tailnet's packet filter has no grant for this device, or the
            /// host is off. The device run's case (F4 §1.1).
            case noAnswer
            /// SOCKS connection refused: the host is up, nothing listens there.
            case refused
            /// SOCKS host / network unreachable.
            case unreachable
            /// SOCKS general failure within 2 s of the attempt: the node
            /// answered at once that it could not, which is what it does while
            /// it is still settling after `Running`.
            case proxyNotReady
            /// The connection never reached the tailnet node: the proxy on
            /// this phone (the relay, or tsnet's loopback listener) refused it
            /// (R30's territory).
            case proxyDown
            /// -1001: connected, never answered.
            case timedOutAfterConnect
            /// -1200…-1206.
            case certificate
            /// D7: a bare name no peer carries.
            case unknownHost(String)
            /// D7: a bare name several peers carry.
            case ambiguousHost(String, [String])
            /// WebKitErrorDomain 102 with nothing committed and no refused
            /// response on record: the gateway's first answer was a redirect
            /// off the origin, which the navigation policy handed away (R3).
            case redirectedAway(String)
            /// D10: a main-frame 5xx, refused in `decidePolicyFor
            /// navigationResponse` (F4 §4.13).
            case gatewayError(status: Int)
            /// D9, after `ContentProcessRecovery`'s budget (R7).
            case pageCrashed(times: Int, window: Int)
            /// The owner chose another gateway mid-load.
            case stopped
            /// `URL(string:)` failed (`reportURLParseFailure`): the one real
            /// format error.
            case badAddress
            case other(domain: String, code: Int)
        }

        /// The first DNS label, as the owner knows the host ("byskebox").
        let host: String
        let fqdn: String
        let port: Int
        let cause: Cause
        /// Since the first attempt. Zero when there was no connecting state
        /// (a parse failure, a crash of a committed page).
        let elapsed: Duration
        let domain: String
        let code: Int
        /// The relay's reply for this very connection, when it recorded one
        /// (`TSNetModel.lastProxyFailure`, matched on target and time).
        let proxyReply: ProxyReply?
        /// For D10: what the refused response carried, for the details.
        let responseContentType: String?
        let responseBodyLength: Int?

        nonisolated init(host: String, fqdn: String, port: Int, cause: Cause, elapsed: Duration,
                         domain: String, code: Int, proxyReply: ProxyReply? = nil,
                         responseContentType: String? = nil, responseBodyLength: Int? = nil) {
            self.host = host
            self.fqdn = fqdn
            self.port = port
            self.cause = cause
            self.elapsed = elapsed
            self.domain = domain
            self.code = code
            self.proxyReply = proxyReply
            self.responseContentType = responseContentType
            self.responseBodyLength = responseBodyLength
        }

        /// The same failure with the relay's reply attached and the cause
        /// decided again from it. The relay publishes its reply from its own
        /// queue and WebKit delivers the error from its own process; which
        /// lands on the main actor first is not guaranteed, so a reply that
        /// arrives just after the failure upgrades the verdict rather than
        /// being lost.
        nonisolated func attaching(_ reply: ProxyReply) -> Failure {
            Failure(host: host, fqdn: fqdn, port: port,
                    cause: PageFailureText.cause(domain: domain, code: code, proxyReply: reply, elapsed: elapsed),
                    elapsed: elapsed, domain: domain, code: code, proxyReply: reply,
                    responseContentType: responseContentType, responseBodyLength: responseBodyLength)
        }
    }

    /// Whole seconds since `since`, never negative. What every ticking label
    /// shows, and what the failure wording's `<t>` is: floored, not rounded,
    /// because a 22 s stall reads "22 s" whatever the delivery overhead adds,
    /// and a number that is never ahead of the clock cannot be seen going
    /// backwards on a later look.
    nonisolated static func elapsedSeconds(since: ContinuousClock.Instant,
                                           now: ContinuousClock.Instant = .now) -> Int {
        max(0, Int(since.duration(to: now).components.seconds))
    }

    /// Whether a "still trying" hint is due: `delay` or more since `since`.
    /// The threshold rule the views share (`StalledHint`), pure so the host
    /// test can pin it; no harness can hold the node in `Starting`.
    nonisolated static func hintIsDue(since: ContinuousClock.Instant, delay: Duration,
                                      now: ContinuousClock.Instant = .now) -> Bool {
        since.duration(to: now) >= delay
    }

    /// Milliseconds of a duration, for the `after N ms` log lines.
    nonisolated static func milliseconds(_ d: Duration) -> Int {
        Int(d.components.seconds) * 1000 + Int(d.components.attoseconds / 1_000_000_000_000_000)
    }

    /// The name in the `page-state:` log lines.
    nonisolated var logName: String {
        switch self {
        case .idle: return "idle"
        case .holding: return "holding"
        case .connecting: return "connecting"
        case .committed: return "committed"
        case .failed: return "failed"
        }
    }

    /// Whether `PageStateView` draws nothing over the web view. Holding,
    /// connecting and failed each have a block, even if connecting's appears
    /// only after a delay. `BrowserView` keeps the web view out of the
    /// accessibility tree otherwise (F9).
    nonisolated var leavesWebViewUncovered: Bool {
        switch self {
        case .idle, .committed: return true
        case .holding, .connecting, .failed: return false
        }
    }
}

extension PageState.Failure.Cause {
    /// The `cause=` token in the `page-state: failed` log line.
    nonisolated var logName: String {
        switch self {
        case .noAnswer: return "noAnswer"
        case .refused: return "refused"
        case .unreachable: return "unreachable"
        case .proxyNotReady: return "proxyNotReady"
        case .proxyDown: return "proxyDown"
        case .timedOutAfterConnect: return "timedOutAfterConnect"
        case .certificate: return "certificate"
        case .unknownHost: return "unknownHost"
        case .ambiguousHost: return "ambiguousHost"
        case .redirectedAway: return "redirectedAway"
        case .gatewayError(let status): return "gatewayError status=\(status)"
        case .pageCrashed: return "pageCrashed"
        case .stopped: return "stopped"
        case .badAddress: return "badAddress"
        case .other: return "other"
        }
    }
}
