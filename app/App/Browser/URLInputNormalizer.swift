// Copyright (c) Tailscale Inc & contributors
// SPDX-License-Identifier: BSD-3-Clause

//
//  URLInputNormalizer.swift
//  Latchkey
//
//  Turns whatever a human typed into something `URL(string:)` and
//  `WKWebView.load` will accept.
//
//  Upstream these two functions were statics on `BrowserNavigator`, the iPad
//  address-bar view. Latchkey has no address bar (PLAN §1.5) but still needs
//  the normalization for the Settings home-page field and, later, for the
//  manually-entered gateway hostname in M5. Extracted here rather than left as
//  statics on a deleted view. The bodies are upstream's, unchanged — they
//  encode iPad keyboard-mangling workarounds that were expensive to find.
//

import Foundation

enum URLInputNormalizer {
    /// Trims leading/trailing whitespace from a URL input, including the
    /// Unicode whitespace characters (U+00A0 non-breaking space, U+200B
    /// zero-width space, etc.) that `.whitespacesAndNewlines` misses and that
    /// the iOS keyboard can insert.
    static func trimmed(_ input: String) -> String {
        // Strip ALL Unicode whitespace from both ends (CharacterSet.whitespaces
        // includes U+00A0; .whitespacesAndNewlines in some SDKs did not).
        let ws = CharacterSet.whitespaces.union(.newlines)
        var s = input.trimmingCharacters(in: ws)
        // Also drop any stray zero-width / non-breaking spaces anywhere — a
        // keyboard can inject them mid-string and they break URL parsing.
        let invisibles: Set<Character> = ["\u{00A0}", "\u{200B}", "\u{200C}", "\u{200D}", "\u{FEFF}"]
        s = String(s.filter { !invisibles.contains($0) })
        return s.trimmingCharacters(in: ws)
    }

    /// Normalizes a URL input into a string suitable for `URL(string:)` /
    /// `WKWebView.load`. A scheme-less bareword denotes a tailnet host and gets
    /// `http://`; other scheme-less hosts get `https://`. Explicit http(s) is
    /// preserved. Additionally — to survive real-keyboard input mangling on
    /// iPad (where `.textInputAutocapitalization(.never)` /
    /// `.autocorrectionDisabled()` are not always honored, so autocorrect can
    /// mutate `https` into a non-http scheme) — if the parsed scheme is
    /// anything other than http or https, strips that scheme and prepends
    /// `https://` instead. A non-http scheme would otherwise parse as a valid
    /// `URL` but be rejected by `WKWebView` as an invalid URL, which is the
    /// reported iPad symptom.
    static func normalized(from input: String) -> String {
        // Fast path: already explicitly http(s) — the overwhelmingly common case.
        let lower = input.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            return input
        }
        if let url = URL(string: input), let scheme = url.scheme, !scheme.isEmpty {
            let s = scheme.lowercased()
            if s == "http" || s == "https" {
                return input
            }
            // A non-http scheme WITH "://" is treated as autocorrect-mangled
            // input (e.g. "httpd://host"); strip the scheme and re-home under
            // https.
            if let r = input.range(of: "://") {
                return "https://\(input[r.upperBound...])"
            }
            // A non-http scheme WITHOUT "://" — including a bare
            // "host:port[/path]" which URL(string:) mis-parses as
            // "scheme:opaque" (scheme = the host) — is scheme-less browser
            // input. Fall through to the default-scheme logic below so a
            // tailnet bare host defaults to HTTP ("randomhost" and
            // "randomhost:7575" both use http, matching each other) and an
            // internet host to HTTPS.
        }
        let scheme = TailnetHostnameQualifier.defaultScheme(forSchemeLessInput: input)
        return "\(scheme)://\(input)"
    }
}
