// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

//
//  LogRedaction.swift
//  Latchkey
//
//  Keeps credentials out of every log line (revision R1, finding H1).
//
//  The dashboard authenticates with a signed token in the URL query
//  (`/?token=…`), and a URL is the single most common thing a browser logs. So
//  the rule is simple: a URL in a log line keeps scheme, host, port and path,
//  and loses query, fragment and userinfo. The token is never in the path.
//
//  Two layers, on purpose:
//
//  1. Call sites that log a `URL` use `url.redactedForLog` explicitly. This is
//     the primary control, and it is greppable.
//  2. `Logger.log` runs every line through `LogRedaction.scrub` as a
//     backstop. It catches what the call sites cannot: an `NSError`'s
//     `userInfo`, which prints `NSErrorFailingURLStringKey` with the full query
//     whenever an error is interpolated; libtailscale's own Go-side messages,
//     which arrive through the same `LogSink`; and the next log line someone
//     writes without thinking about any of this.
//
//  Pure Foundation, no app types, so `scripts/test-log-redaction.sh` compiles
//  it on the host with nothing else.
//

import Foundation

extension URL {
    /// `scheme://host[:port]/path`, with a marker where a query or fragment
    /// was dropped. Never the query, fragment, user or password.
    ///
    /// The markers (`?…`, `#…`) are there so a log reader can tell "this URL
    /// had parameters" from "this URL had none" — which is often the whole
    /// diagnosis — without seeing what they were.
    nonisolated var redactedForLog: String {
        LogRedaction.redact(self)
    }
}

enum LogRedaction {
    /// See `URL.redactedForLog`.
    nonisolated static func redact(_ url: URL) -> String {
        guard let scheme = url.scheme?.lowercased() else {
            return "<url>"
        }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host, !host.isEmpty
        else {
            // No authority: about:blank, data:, mailto:, blob:… Only `about:`
            // is safe to print whole; everything else may carry its payload
            // in the opaque part (a data: URL can be the entire document).
            if scheme == "about" {
                return "about:" + (url.absoluteString
                    .dropFirst("about:".count)
                    .split(separator: "?", maxSplits: 1).first
                    .map(String.init) ?? "")
            }
            return scheme + ":…"
        }
        var out = scheme + "://"
        // Current Foundation returns IPv6 literals with their brackets; older
        // releases returned them bare. Normalise to bracketed either way.
        out += (host.contains(":") && !host.hasPrefix("[")) ? "[\(host)]" : host
        if let port = components.port { out += ":\(port)" }
        out += components.percentEncodedPath
        if components.percentEncodedQuery != nil { out += "?…" }
        if components.percentEncodedFragment != nil { out += "#…" }
        return out
    }

    /// An error, described without leaking the URL it carries.
    ///
    /// `"\(error)"` on an `NSError` prints its whole `userInfo`, which for a
    /// URL loading error includes `NSErrorFailingURLStringKey` and
    /// `NSErrorFailingURLKey` — the full URL, query and all.
    nonisolated static func describe(_ error: Error) -> String {
        let ns = error as NSError
        var out = "\(ns.domain) \(ns.code): \(ns.localizedDescription)"
        if let url = ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL {
            out += " (url: \(url.redactedForLog))"
        }
        return scrub(out)
    }

    /// Redacts every URL and every bare `token=` parameter in free text.
    ///
    /// Cheap on the common path: most log lines contain neither `://` nor
    /// `token`, and those return untouched without a regex running.
    nonisolated static func scrub(_ message: String) -> String {
        guard message.contains("://") || message.range(of: "token", options: .caseInsensitive) != nil
        else { return message }

        var result = message
        let whole = NSRange(result.startIndex..., in: result)

        // URLs. Replace back to front so earlier ranges stay valid.
        for match in urlPattern.matches(in: result, range: whole).reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let candidate = String(result[range])
            let replacement = URL(string: candidate).map(redact) ?? stripParameters(candidate)
            result.replaceSubrange(range, with: replacement)
        }

        // A `token=` that is not inside a URL — a form body, a JSON field, a
        // message that quotes a query string. Reported as a marker so the
        // line still reads sensibly.
        let remaining = NSRange(result.startIndex..., in: result)
        result = bareTokenPattern.stringByReplacingMatches(
            in: result, range: remaining, withTemplate: "[token redacted]")
        return result
    }

    /// Fallback for text that looks like a URL but does not parse as one:
    /// cut at the first `?` or `#`.
    nonisolated private static func stripParameters(_ candidate: String) -> String {
        guard let cut = candidate.firstIndex(where: { $0 == "?" || $0 == "#" }) else {
            return candidate
        }
        return String(candidate[..<cut]) + (candidate[cut] == "?" ? "?…" : "#…")
    }

    // `nonisolated(unsafe)`: NSRegularExpression is immutable after init and
    // documented thread-safe for matching; this module's default actor
    // isolation is MainActor, and `scrub` runs on libtailscale's Go threads.
    nonisolated(unsafe) private static let urlPattern = try! NSRegularExpression(
        pattern: #"[A-Za-z][A-Za-z0-9+.\-]*://[^\s"'<>]+"#)

    nonisolated(unsafe) private static let bareTokenPattern = try! NSRegularExpression(
        pattern: #"(?i)\btoken=[^&\s"',;}]*"#)
}
