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
expectEqual(URL(string: "https://byskebox.example.ts.net/")!.redactedForLog,
            "https://byskebox.example.ts.net/", "plain origin is unchanged")
expectEqual(URL(string: "https://byskebox.example.ts.net/?token=\(secret)")!.redactedForLog,
            "https://byskebox.example.ts.net/?…", "token query is dropped, marker kept")
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
let socks = "socks[42] OK byskebox.example.ts.net:443 (14ms)"
expectEqual(LogRedaction.scrub(socks), socks, "SOCKS CONNECT line (host:port only) is untouched")

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
