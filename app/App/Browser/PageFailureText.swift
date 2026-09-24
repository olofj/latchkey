// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

//
//  PageFailureText.swift
//  Latchkey
//
//  What the error page says, and how a failure's cause is decided (F4 §4.4).
//
//  The words are the spec's, final. They exist because the page used to say
//  "Unable to Load Page / URL format error / bad URL [NSURLErrorDomain
//  -1000]" for every SOCKS failure -- WebKit reports each reply code as -1000
//  -- and offered no button. An owner whose new phone had no grant in the
//  tailnet's packet filter was told the address was malformed.
//
//  The cause is decided from three facts the code actually has: the error's
//  domain and code, the relay's reply for that connection when it recorded one
//  (`ProxyReply`), and how long the attempt took. "No answer in 30 s" and
//  "general failure at once" are the same -1000 to WebKit and mean opposite
//  things to the owner.
//
//  Pure Foundation, `nonisolated`: `scripts/test-page-failure-text.sh`
//  compiles this file, `PageState.swift` and `SocksRelayPolicy.swift` alone.
//

import Foundation

nonisolated enum PageFailureText {

    /// Below this, a SOCKS "general failure" is the node answering at once
    /// that it cannot dial -- it is still settling after `Running` -- and the
    /// owner should simply try again. At or above it the dial ran and nothing
    /// came back: dropped SYNs, which no retry fixes. tsnet's dial deadline is
    /// 30 s (`socks5.go:99`); 2 s is far from both ends.
    nonisolated static let noAnswerThreshold: Duration = .seconds(2)

    /// The cause a failure gets, from what the code knows.
    nonisolated static func cause(domain: String, code: Int, proxyReply: ProxyReply?,
                                  elapsed: Duration) -> PageState.Failure.Cause {
        guard domain == NSURLErrorDomain else { return .other(domain: domain, code: code) }
        switch code {
        case NSURLErrorBadURL:
            // -1000: WebKit's name for EVERY SOCKS failure reply (measured;
            // TailnetProxyPolicy.swift's header). Never a format error: the
            // one string URL(string:) rejects never reaches a navigation, and
            // `reportURLParseFailure` sets `.badAddress` itself.
            switch proxyReply?.reply {
            case "connection refused":
                return .refused
            case "host unreachable", "network unreachable":
                return .unreachable
            default:
                // "general failure", or no reply on record (the relay is off,
                // or its publication has not landed yet). tsnet answers
                // general failure for everything it cannot name, a deadline
                // included (`replyCodeForDialError`, socks5.go:687-697), so
                // the elapsed time is what tells the two cases apart.
                return elapsed >= noAnswerThreshold ? .noAnswer : .proxyNotReady
            }
        case NSURLErrorTimedOut:
            return .timedOutAfterConnect
        case -1206 ... -1200:
            // NSURLErrorSecureConnectionFailed through
            // NSURLErrorClientCertificateRequired: the TLS family.
            return .certificate
        case NSURLErrorCannotConnectToHost, NSURLErrorNotConnectedToInternet:
            // Measured over 25 runs each (OfflineHarnessTests): -1004 when
            // WebKit dials a dead proxy itself, -1009 when the relay accepted
            // and tsnet's port under it refused. Both mean the connection
            // never left the phone. F4 §4.4 put this row under -1000 with
            // relay evidence; the codes say it without any.
            return .proxyDown
        default:
            return .other(domain: domain, code: code)
        }
    }

    /// The host as the title shows it: the label, with the port when it is
    /// not 443 (F4 §3, F1).
    nonisolated static func displayHost(_ host: String, port: Int) -> String {
        port == 443 ? host : "\(host):\(port)"
    }

    /// The error page's three lines (F4 §4.4, verbatim).
    nonisolated static func lines(for f: PageState.Failure) -> (title: String, cause: String, next: String) {
        let h = f.host
        let p = f.port
        let t = max(0, Int(f.elapsed.components.seconds))
        let shown = displayHost(h, port: p)
        switch f.cause {
        case .noAnswer:
            return ("Couldn't reach \(shown)",
                    "\(h) didn't answer on port \(p) in \(t) s. The tailnet dropped the connection, which usually means this device isn't allowed to reach \(h) yet, or \(h) is off.",
                    "Whoever manages the tailnet needs this device's address (Settings → Status). If \(h) is on, try again in a moment.")
        case .proxyNotReady:
            let reply = f.proxyReply?.reply ?? "general failure"
            return ("Couldn't reach \(shown)",
                    "The tailnet node couldn't open a connection to \(h):\(p) (it answered \"\(reply)\" after \(t) s). The node may still be settling.",
                    "Try again. If it keeps happening, Settings → Node log.")
        case .refused:
            return ("Couldn't reach \(shown)",
                    "\(h) is reachable but refused the connection on port \(p): nothing is listening there.",
                    "Is Kiro Crew's dashboard served on port \(p)? Choose another gateway, or correct the port in Settings.")
        case .unreachable:
            return ("Couldn't reach \(shown)",
                    "The tailnet has no route to \(h) right now.",
                    "Try again in a moment; if it persists, Settings → Status shows the node's state.")
        case .proxyDown:
            return ("Couldn't reach \(shown)",
                    "The connection never reached the tailnet node: its proxy on this phone didn't answer.",
                    "Try again; Latchkey has restarted the proxy. If it persists, Settings → Status → Proxy.")
        case .timedOutAfterConnect:
            return ("Couldn't reach \(shown)",
                    "\(h) accepted the connection on port \(p) but sent nothing in \(t) s.",
                    "Try again. If \(h) keeps accepting and never answering, its gateway is up but stuck.")
        case .certificate:
            return ("Couldn't reach \(shown)",
                    "\(h) answered on port \(p), but its certificate isn't valid for \(f.fqdn).",
                    "Latchkey only opens a gateway with a valid certificate (R28). Check the gateway's tailscale serve certificate.")
        case .unknownHost(let name):
            return ("Couldn't reach \(shown)",
                    "No device named “\(name)” exists in this tailnet.",
                    "Check the name, or choose another gateway.")
        case .ambiguousHost(let name, let candidates):
            return ("Couldn't reach \(shown)",
                    "More than one tailnet device matches “\(name)”: \(candidates.joined(separator: ", ")).",
                    "Enter the full name.")
        case .redirectedAway(let destination):
            return ("Couldn't open \(shown) here",
                    "\(h) redirected to \(destination), which isn't the gateway this app is set to, so it wasn't opened here.",
                    "Check the gateway address in Settings.")
        case .gatewayError(let status):
            if [502, 503, 504].contains(status) {
                // `tailscale serve` speaking for a Kiro Crew that is not there:
                // 502 from a reverse proxy with no error handler (serve.go:959-994),
                // 503 while serve itself reconfigures (:955-957).
                return ("Couldn't reach Kiro Crew on \(shown)",
                        "\(h) answered on port \(p), but Kiro Crew behind it didn't: tailscale serve returned \(status) after \(t) s, which is what it says when nothing is listening behind it. Kiro Crew is probably restarting or stopped on \(h).",
                        "Try again in a few seconds — a restart is normally over by then. If it keeps happening, Kiro Crew isn't running on \(h): start it there, or choose another gateway.")
            }
            return ("Kiro Crew on \(shown) hit an error",
                    "\(h) answered \(status) for the dashboard page after \(t) s: Kiro Crew is running but couldn't serve it.",
                    "Try again. If it persists, Kiro Crew's own log on \(h) says why.")
        case .pageCrashed(let times, let window):
            return ("The page stopped",
                    "The dashboard page stopped \(times) times in \(window) s, so automatic reloading has paused. This is the page itself, not the tailnet.",
                    "Try again.")
        case .stopped:
            return ("Stopped",
                    "You stopped the connection to \(h) after \(t) s.",
                    "Try again, or choose another gateway.")
        case .badAddress:
            return ("Latchkey can't open this address",
                    "The address has a character it can't use; the details show it escaped.",
                    "Correct the gateway in Settings.")
        case .other(let domain, let code):
            return ("Couldn't load \(shown)",
                    "\(h) could not be loaded (\(domain) \(code)).",
                    "Try again.")
        }
    }

    /// The Details disclosure (F4 §3.2): the escaped URL, the error, the
    /// relay's reply or the refused response, and where the record is kept.
    /// D1 holds -- nothing leaves the device; this is where a failure is read.
    nonisolated static func details(for f: PageState.Failure, urlString: String) -> [String] {
        var out: [String] = []
        if !urlString.isEmpty {
            out.append("URL (escaped): \(debugEscaped(urlString))")
        }
        out.append("\(f.domain) \(f.code)")
        if let reply = f.proxyReply {
            out.append("Tailnet proxy replied: \(reply.reply) after \(PageState.milliseconds(reply.elapsed)) ms")
        }
        if case .gatewayError(let status) = f.cause {
            let type = f.responseContentType.map { $0.isEmpty ? "none" : $0 } ?? "none"
            let length = f.responseBodyLength.map { "\($0) bytes" } ?? "length unknown"
            out.append("HTTP \(status), Content-Type \(type), body \(length)")
        }
        out.append("Settings → Status → Page keeps this; Logs has the full record.")
        return out
    }

    /// One line for Settings → Status → Page → "State" (F4 §4.11).
    nonisolated static func describe(_ state: PageState, now: ContinuousClock.Instant = .now) -> String {
        switch state {
        case .idle:
            return "idle"
        case .holding(let host, let since):
            return "waiting for the peer list before opening \(host) (\(PageState.elapsedSeconds(since: since, now: now)) s)"
        case .connecting(let host, let port, let since, let attempt):
            return "connecting to \(displayHost(host, port: port)) (attempt \(attempt), \(PageState.elapsedSeconds(since: since, now: now)) s)"
        case .committed:
            return "page shown"
        case .failed(let f):
            return "failed: \(f.cause.logName) after \(max(0, Int(f.elapsed.components.seconds))) s"
        }
    }
}

/// Returns a diagnostic, escape-only representation of `s` for the error
/// page's Details: every Unicode scalar outside printable ASCII (0x20–0x7E) is
/// rendered as `\u{XXXX}` so invisible/problematic characters the keyboard may
/// have injected (non-breaking space U+00A0, zero-width space U+200B, smart
/// quotes U+201C/201D, tabs, newlines, etc.) are visible. Printable ASCII
/// (including the regular space) is shown as-is, so a clean URL reads normally.
///
/// Percent-encoding is decoded first, so a percent-encoded bad char (e.g.
/// `%C2%A0` for a non-breaking space that `URL(string:)` encoded) reveals its
/// true scalar (`\u{A0}`) rather than the opaque encoding. It has caught
/// invisible characters before, which is why F4 keeps it under Details.
nonisolated func debugEscaped(_ s: String) -> String {
    let decoded = s.removingPercentEncoding ?? s
    var out = ""
    for scalar in decoded.unicodeScalars {
        if scalar.value >= 0x20 && scalar.value <= 0x7E {
            out += String(scalar)
        } else {
            out += String(format: "\\u{%X}", scalar.value)
        }
    }
    return out
}
