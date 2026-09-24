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
    /// Login links carry their secret in the PATH, where the query/fragment
    /// rule does not reach: Tailscale's `https://login.tailscale.com/a/<code>`
    /// (anyone holding it can finish the login -- with THEIR account) and a
    /// control plane's `/auth/<id>` (testcontrol, headscale). The path is
    /// kept up to the secret, so the line still says what it was (M8.3).
    ///
    /// A secret is a run of `secretFloor`+ characters right after the prefix,
    /// stopping at a `/` or whitespace. **Deliberately no character set:** the
    /// login URL is not built here, it arrives from the control server as
    /// `resp.AuthURL`, so its shape is Tailscale's to change. Until 2026-09-23
    /// both this and the vendored Go redactor required 8+ ASCII alphanumerics
    /// and matched the prefix case-sensitively, so a code containing a hyphen —
    /// or a `/A/` — passed through in plain text. The L2 harness now mints
    /// hostile codes by default so this cannot regress silently.
    ///
    /// The length floor is why this differs from the Go rule, which cuts
    /// everything after the prefix: that one only ever sees tsnet's own log
    /// lines, while this one also scrubs dashboard URLs, where `/chat/a/b` is an
    /// ordinary path and should keep its shape.
    nonisolated static func redactSecretPath(_ path: String) -> String {
        let lower = path.lowercased()
        for prefix in ["/a/", "/auth/"] where lower.hasPrefix(prefix) {
            let rest = path.dropFirst(prefix.count)
            let secret = rest.prefix { !$0.isWhitespace && $0 != "/" }
            if secret.count >= secretFloor {
                // Keep the path's own spelling of the prefix, not the folded one.
                return path.prefix(prefix.count) + "…" + rest.dropFirst(secret.count)
            }
        }
        return path
    }

    /// Shortest run after `/a/` or `/auth/` treated as a secret rather than a
    /// path segment. Six: the shortest login code worth worrying about, and
    /// still long enough to leave `/chat/a/b` and `/a/me` alone.
    nonisolated static let secretFloor = 6

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
        out += redactSecretPath(components.percentEncodedPath)
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

    /// Redacts every URL, every login code in a path, and every bare
    /// `token=` parameter in free text.
    ///
    /// Cheap on the common path: most log lines contain none of `://`, `/a/`,
    /// `/auth/` or `token`, and those return untouched without a regex running.
    nonisolated static func scrub(_ message: String) -> String {
        guard message.contains("://") || message.contains("/a/") || message.contains("/auth/")
                || message.range(of: "token", options: .caseInsensitive) != nil
        else { return message }

        var result = message
        let whole = NSRange(result.startIndex..., in: result)

        // URLs. Replace back to front so earlier ranges stay valid.
        for match in urlPattern.matches(in: result, range: whole).reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let (candidate, tail) = trimTrailingPunctuation(String(result[range]))
            let replacement = URL(string: candidate).map(redact) ?? stripParameters(candidate)
            result.replaceSubrange(range, with: replacement + tail)
        }

        // A login code in a path that was not a parseable URL: no scheme
        // (`login.tailscale.com/a/<code>`), or text the URL parse mangled.
        result = secretPathPattern.stringByReplacingMatches(
            in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "/$1/…")

        // A `token=` that is not inside a URL — a form body, a JSON field, a
        // message that quotes a query string. Reported as a marker so the
        // line still reads sensibly.
        let remaining = NSRange(result.startIndex..., in: result)
        result = bareTokenPattern.stringByReplacingMatches(
            in: result, range: remaining, withTemplate: "[token redacted]")
        return result
    }

    /// Sentence punctuation after a URL (`…/a/<code>.`, `(…/a/<code>)`) is not
    /// part of it; a closing bracket is, if the URL opened one (`http://[::1]`).
    nonisolated private static func trimTrailingPunctuation(_ candidate: String) -> (String, String) {
        var url = Substring(candidate)
        while let last = url.last {
            let unbalanced = (last == ")" && url.filter { $0 == "(" }.count < url.filter { $0 == ")" }.count)
                || (last == "]" && url.filter { $0 == "[" }.count < url.filter { $0 == "]" }.count)
            guard ".,;:!?}".contains(last) || unbalanced else { break }
            url = url.dropLast()
        }
        return (String(url), String(candidate.dropFirst(url.count)))
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
        pattern: #"[A-Za-z][A-Za-z0-9+.\-]*://[^\s"'<>\\`{]+"#)

    /// Charset-agnostic and case-insensitive, for the reasons on
    /// `redactSecretPath`: the code's shape belongs to the control server. The
    /// class excludes `/` and the characters that end a URL in prose, so a
    /// following path segment or closing quote survives, and the `{6,}` floor
    /// keeps ordinary paths like `/chat/a/b` intact.
    nonisolated(unsafe) private static let secretPathPattern = try! NSRegularExpression(
        pattern: #"(?i)/(a|auth)/[^\s"'<>\\`/]{6,}"#)

    nonisolated(unsafe) private static let bareTokenPattern = try! NSRegularExpression(
        pattern: #"(?i)\btoken=[^&\s"',;}]*"#)
}
