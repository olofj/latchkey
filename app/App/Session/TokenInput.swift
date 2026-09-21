// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

//
//  TokenInput.swift
//  Latchkey
//
//  Turns whatever the user pasted, typed or scanned into a sign-in token
//  (M4.4, revision R23). Foundation only, so scripts/test-token-input.sh can
//  compile it on the host.
//
//  What people paste:
//   - `kirocrew token` output: up to THREE URLs on separate lines (localhost,
//     `dashboard.url`, the tailnet name), all carrying the same token. A
//     multi-line paste is not a URL, so the page banner's
//     `new URL(input).searchParams.get("token")` fails on it; a regex does not.
//   - A single sign-in URL, from a QR code or a message.
//   - A bare token.
//
//  The host in a pasted link is reported, never used: the app always signs in
//  to the SELECTED gateway (anti-QR-phishing). Tokens are signed per gateway,
//  so a link for another gateway simply fails there.
//

import Foundation

enum TokenInput {
    struct Parsed: Equatable {
        /// The token, percent-encoded as it goes into a query.
        let token: String
        /// The host of the link the token came from, if it came from a link.
        let linkHost: String?
    }

    // Closures, never unapplied `set.contains` references: under -O, Swift
    // 6.4 merged two such thunks and the whitespace check tested THIS set
    // instead (every token "contained whitespace"). -Onone was fine, so only
    // Release would have broken. See DECISIONS, M4.

    /// Characters a token may contain, in its query-encoded form.
    private static let tokenCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~%+/=")
    /// Unreserved characters: a bare token is encoded down to these.
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    /// Real tokens are long signed strings; anything shorter is a typo.
    static let minimumBareTokenLength = 16

    static func parse(_ raw: String) -> Parsed? {
        // A link: the first `token=` parameter anywhere in the text.
        if let match = firstTokenParameter(in: raw) {
            guard !match.token.isEmpty,
                  match.token.unicodeScalars.allSatisfy({ tokenCharacters.contains($0) })
            else { return nil }
            return Parsed(token: match.token, linkHost: match.host)
        }
        // Otherwise a bare token: one word, no URL syntax.
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= minimumBareTokenLength,
              !trimmed.contains("://"),
              !trimmed.contains(where: { $0.isWhitespace || $0.isNewline }),
              trimmed.unicodeScalars.allSatisfy({ tokenCharacters.contains($0) })
        else { return nil }
        // Already percent-encoded if it contains '%'; otherwise encode, so a
        // '+' or '/' survives the query.
        let encoded = trimmed.contains("%")
            ? trimmed
            : (trimmed.addingPercentEncoding(withAllowedCharacters: unreserved) ?? trimmed)
        return Parsed(token: encoded, linkHost: nil)
    }

    /// `<origin>/?token=<token>`. Always the selected gateway's origin.
    static func signInURL(origin: URL, token: String) -> URL? {
        var base = origin.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        return URL(string: base + "/?token=" + token)
    }

    private static func firstTokenParameter(in text: String) -> (token: String, host: String?)? {
        // Split into whitespace-separated words; the first word carrying a
        // `token=` query parameter wins.
        for word in text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }) {
            let w = String(word).trimmingCharacters(in: CharacterSet(charactersIn: "\"'<>()[],;"))
            guard let range = w.range(of: #"[?&]token="#, options: .regularExpression) else { continue }
            let value = w[range.upperBound...].prefix { $0 != "&" && $0 != "#" }
            let host = URLComponents(string: w)?.host
            return (String(value), host)
        }
        return nil
    }
}
