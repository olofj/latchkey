// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

// Host-only tests for App/Logging/LogRedaction.swift (revision R1).
//
// Run:  make test-policy     (or: scripts/test-log-redaction.sh)

import Foundation

var failures = 0
var checks = 0

func expectEqual(_ got: String, _ want: String, _ what: String) {
    checks += 1
    if got != want {
        failures += 1
        print("  FAIL: \(what)\n        got:      \(got)\n        expected: \(want)")
    }
}

func expectAbsent(_ haystack: String, _ needle: String, _ what: String) {
    checks += 1
    if haystack.contains(needle) {
        failures += 1
        print("  FAIL: \(what)\n        '\(needle)' found in: \(haystack)")
    }
}

func section(_ name: String) { print("\n== \(name)") }

let secret = "eyJhbGciOiJIUzI1NiJ9.SECRET-TOKEN-VALUE.sig"

section("URL.redactedForLog keeps scheme, host, port, path")
expectEqual(URL(string: "https://gateway.example.ts.net/")!.redactedForLog,
            "https://gateway.example.ts.net/", "plain origin is unchanged")
expectEqual(URL(string: "https://gateway.example.ts.net/?token=\(secret)")!.redactedForLog,
            "https://gateway.example.ts.net/?…", "token query is dropped, marker kept")
expectEqual(URL(string: "https://h.example:8443/a/b?x=1&token=\(secret)#frag")!.redactedForLog,
            "https://h.example:8443/a/b?…#…", "port and path kept; query and fragment dropped")
expectEqual(URL(string: "https://user:pass@h.example/p")!.redactedForLog,
            "https://h.example/p", "userinfo is dropped")
expectEqual(URL(string: "http://[fd7a:115c:a1e0::1]:5476/x?token=\(secret)")!.redactedForLog,
            "http://[fd7a:115c:a1e0::1]:5476/x?…", "IPv6 literal keeps its brackets")
expectEqual(URL(string: "about:blank")!.redactedForLog, "about:blank", "about:blank is printed whole")
expectEqual(URL(string: "data:text/html,<p>\(secret)</p>")!.redactedForLog,
            "data:…", "a data: URL's payload is never printed")
expectEqual(URL(string: "mailto:someone@example.com?subject=hi")!.redactedForLog,
            "mailto:…", "an opaque URL's payload is never printed")

section("scrub: URLs inside free text")
let line = "Navigation error for https://dash.tail-scale.ts.net/?token=\(secret): boom"
expectAbsent(LogRedaction.scrub(line), secret, "token value removed from a URL in text")
expectAbsent(LogRedaction.scrub(line), "token=", "no 'token=' survives (R1 AC greps for it)")
checks += 1
if !LogRedaction.scrub(line).contains("https://dash.tail-scale.ts.net/?…") {
    failures += 1
    print("  FAIL: the redacted URL should still be readable in the line\n        got: \(LogRedaction.scrub(line))")
}

section("scrub: an NSError's userInfo")
let nsError = NSError(domain: NSURLErrorDomain, code: -1004, userInfo: [
    NSURLErrorFailingURLErrorKey: URL(string: "https://dash.tail-scale.ts.net/?token=\(secret)")!,
    // The string key by name: the constant is deprecated, but CFNetwork still
    // populates this key, and it is exactly what leaks through interpolation.
    "NSErrorFailingURLStringKey": "https://dash.tail-scale.ts.net/?token=\(secret)",
    NSLocalizedDescriptionKey: "Could not connect to the server.",
])
let interpolated = "load failed: \(nsError)"
checks += 1
if !interpolated.contains(secret) {
    failures += 1
    print("  FAIL: test premise broken — NSError interpolation no longer includes userInfo")
}
expectAbsent(LogRedaction.scrub(interpolated), secret, "interpolated NSError is scrubbed")
expectAbsent(LogRedaction.scrub(interpolated), "token=", "interpolated NSError keeps no 'token='")
expectAbsent(LogRedaction.describe(nsError), secret, "describe(error) never includes the token")
checks += 1
if !LogRedaction.describe(nsError).contains("NSURLErrorDomain -1004") {
    failures += 1
    print("  FAIL: describe(error) should keep domain and code: \(LogRedaction.describe(nsError))")
}

section("scrub: bare token parameters outside a URL")
expectAbsent(LogRedaction.scrub("POST body token=\(secret)&x=1"), secret, "form body token removed")
expectAbsent(LogRedaction.scrub(#"{"token=\#(secret)"}"#), secret, "quoted token removed")
expectAbsent(LogRedaction.scrub("TOKEN=\(secret)"), secret, "case-insensitive")

section("scrub: lines without URLs or tokens are untouched")
let plain = "State: Running; 12 peers; proxyConfig: split tunnel, proxying 3 rule(s)"
expectEqual(LogRedaction.scrub(plain), plain, "ordinary line is returned as-is")
let socks = "socks[42] OK gateway.example.ts.net:443 (14ms)"
expectEqual(LogRedaction.scrub(socks), socks, "SOCKS CONNECT line (host:port only) is untouched")

section("scrub: login links carry their secret in the path (M8.3)")
let loginLine = "To start this tsnet server, restart with TS_AUTHKEY set, or go to: https://login.tailscale.com/a/4653479012c06"
expectAbsent(LogRedaction.scrub(loginLine), "4653479012c06", "a Tailscale login code is removed")
expectEqual(LogRedaction.scrub("go to: https://login.tailscale.com/a/4653479012c06"),
            "go to: https://login.tailscale.com/a/…", "and the link keeps its shape")
expectEqual(LogRedaction.scrub("opening http://127.0.0.1:8490/auth/0123456789abcdef0123"),
            "opening http://127.0.0.1:8490/auth/…", "a control plane's /auth/<id> is removed")
let dashPath = "loaded https://gw.example.ts.net/chat/a/b"
expectEqual(LogRedaction.scrub(dashPath), dashPath, "a short segment under /a/ anywhere is left alone")
expectEqual(LogRedaction.scrub("loaded https://gw.example.ts.net/chat/a/abcdefgh1234"),
            "loaded https://gw.example.ts.net/chat/a/…",
            "an 8+ code under /a/ ANYWHERE is cut: over-redacting a path beats missing a login code")

// The shape of a login code is the CONTROL SERVER's to choose, not ours: the
// app never builds that URL, it arrives as `resp.AuthURL`. So the rule must not
// assume a character set. These are the shapes the L2 harness now mints by
// default (hostile: hyphenated, mixed-case groups), and the shapes the vendored
// Go redactor was fixed to catch on 2026-09-23. Before that fix both sides
// assumed 8+ ASCII alphanumerics and let every row below through.
for (code, what) in [("0f1e-2d3c-4b5a", "hyphens"),
                     ("Ab3F-9zQ1-Kp7M-2wXe", "hyphens and mixed case"),
                     ("a_b.c~d-e1f2", "underscore, dot and tilde"),
                     ("%41%42%43%44%45%46", "percent-encoded")] {
    expectEqual(LogRedaction.scrub("go to: https://login.example.ts.net/a/\(code)"),
                "go to: https://login.example.ts.net/a/…",
                "a login code with \(what) is cut")
}
expectEqual(LogRedaction.scrub("go to: https://login.example.ts.net/A/0f1e2d3c4b5a6978"),
            "go to: https://login.example.ts.net/A/…",
            "the /A/ prefix is matched case-insensitively")
expectEqual(LogRedaction.scrub("opening http://127.0.0.1:8490/AUTH/Ab3F-9zQ1-Kp7M"),
            "opening http://127.0.0.1:8490/AUTH/…",
            "and so is /AUTH/ with a hostile code")
// The floor stays, so ordinary dashboard paths keep their shape. This is where
// the Swift rule DIVERGES from the Go one, on purpose: the Go redactor only
// ever sees tsnet's own log lines, while this one also scrubs dashboard URLs
// like /chat/a/b. Divergence with a reason is fine; the silent kind is what the
// 2026-09-23 review kept finding.
expectEqual(LogRedaction.scrub("loaded https://gw.example.ts.net/chat/a/b"),
            "loaded https://gw.example.ts.net/chat/a/b",
            "a short segment under /a/ is still left alone")
expectEqual(LogRedaction.redactSecretPath("/a/0f1e-2d3c-4b5a"), "/a/…",
            "redactSecretPath itself is charset-agnostic")
expectEqual(LogRedaction.redactSecretPath("/a/b"), "/a/b",
            "redactSecretPath keeps a short segment")
expectEqual(LogRedaction.scrub("https://login.tailscale.com/a/"), "https://login.tailscale.com/a/",
            "nothing after the prefix: nothing to hide")
expectEqual(LogRedaction.scrub("https://h.example/a/b"), "https://h.example/a/b",
            "a short ordinary path under /a/ is not a login code")

section("scrub: a login code followed by punctuation, or with no scheme (R29 review)")
let code = "4653479012c06"
for line in [
    "go to https://login.tailscale.com/a/\(code).",
    "(https://login.tailscale.com/a/\(code))",
    "https://login.tailscale.com/a/\(code), then",
    "{AuthURL:https://login.tailscale.com/a/\(code)}",
    "[https://login.tailscale.com/a/\(code)]",
    "`https://login.tailscale.com/a/\(code)`",
    "http://127.0.0.1:8490/auth/\(code)abcdef;",
    #"{"url":"https://login.tailscale.com/a/\#(code)\n"}"#,
    "visit login.tailscale.com/a/\(code) to sign in",
] {
    expectAbsent(LogRedaction.scrub(line), code, "code removed from: \(line)")
}
expectEqual(LogRedaction.scrub("go to https://login.tailscale.com/a/\(code)."),
            "go to https://login.tailscale.com/a/….", "the sentence's full stop survives")
expectEqual(LogRedaction.scrub("(see https://gw.example.net/x?token=abc)"),
            "(see https://gw.example.net/x?…)", "a closing parenthesis is not part of the URL")
expectEqual(LogRedaction.scrub("listening on http://[::1]:8080/ and http://[::1]."),
            "listening on http://[::1]:8080/ and http://[::1].", "an IPv6 host keeps its brackets")

section("scrub: several URLs in one line")
let two = "a https://a.example/x?token=AAA then https://b.example/y?token=BBB end"
let scrubbedTwo = LogRedaction.scrub(two)
expectAbsent(scrubbedTwo, "AAA", "first URL scrubbed")
expectAbsent(scrubbedTwo, "BBB", "second URL scrubbed")
expectEqual(scrubbedTwo, "a https://a.example/x?… then https://b.example/y?… end",
            "both URLs keep their shape")

print("")
if failures == 0 {
    print("\(checks)/\(checks) log redaction checks passed")
} else {
    print("\(failures) of \(checks) log redaction checks FAILED")
    exit(1)
}
