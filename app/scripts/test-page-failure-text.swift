// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

// Host-only tests for App/Browser/PageState.swift and PageFailureText.swift
// (F4 §6, tests 5 and 6).
//
// Two things are pinned here. First, that the cause is decided from the three
// facts the code actually has — domain/code, the relay's reply, elapsed —
// because WebKit collapses EVERY SOCKS reply into -1000, so "no answer in 30 s"
// and "general failure at once" arrive identical and mean opposite things.
// Second, that the words say what they claim to: the page used to tell an owner
// whose phone had no grant in the tailnet's packet filter that the address was
// malformed.
//
// Run:  make test-policy     (or: scripts/test-page-failure-text.sh)

import Foundation

var failures = 0
var checks = 0

func expectTrue(_ got: Bool, _ what: String) {
    checks += 1
    if !got {
        failures += 1
        print("  FAIL: \(what)")
    }
}

func expectEqual<T: Equatable>(_ got: T, _ want: T, _ what: String) {
    checks += 1
    if got != want {
        failures += 1
        print("  FAIL: \(what)\n        got:      \(got)\n        expected: \(want)")
    }
}

func section(_ name: String) { print("\n== \(name)") }

func reply(_ r: String, after: Duration = .milliseconds(10)) -> ProxyReply {
    ProxyReply(target: "gw.example.ts.net:443", reply: r, elapsed: after, at: Date())
}

func cause(_ code: Int, _ r: ProxyReply? = nil, _ elapsed: Duration = .seconds(5),
           domain: String = NSURLErrorDomain) -> PageState.Failure.Cause {
    PageFailureText.cause(domain: domain, code: code, proxyReply: r, elapsed: elapsed)
}

func failure(_ c: PageState.Failure.Cause, host: String = "byskebox", port: Int = 443,
             elapsed: Duration = .seconds(7), domain: String = NSURLErrorDomain,
             code: Int = NSURLErrorBadURL, proxyReply: ProxyReply? = nil,
             contentType: String? = nil, bodyLength: Int? = nil) -> PageState.Failure {
    PageState.Failure(host: host, fqdn: "\(host).example.ts.net", port: port, cause: c,
                      elapsed: elapsed, domain: domain, code: code, proxyReply: proxyReply,
                      responseContentType: contentType, responseBodyLength: bodyLength)
}

// MARK: - The cause, from -1000 and what else is known

section("-1000 is never a format error (the shipped bug)")
// The whole reason this file exists. Every branch below is -1000.
for r in [nil, reply("general failure"), reply("connection refused"), reply("host unreachable")] {
    let c = cause(NSURLErrorBadURL, r)
    expectTrue(c != .badAddress,
               "a SOCKS failure (-1000, reply \(r?.reply ?? "none")) is never .badAddress")
}

section("-1000: the relay's reply names the cause when it has one")
expectEqual(cause(NSURLErrorBadURL, reply("connection refused")), .refused,
            "refused: the host is up, nothing listens")
expectEqual(cause(NSURLErrorBadURL, reply("host unreachable")), .unreachable, "host unreachable")
expectEqual(cause(NSURLErrorBadURL, reply("network unreachable")), .unreachable, "network unreachable")

section("-1000 general failure: the elapsed time tells the two cases apart")
// tsnet answers "general failure" for everything it cannot name, a 30 s dial
// deadline included, so the reply alone cannot distinguish these.
expectEqual(cause(NSURLErrorBadURL, reply("general failure"), .seconds(30)), .noAnswer,
            "a dial that ran and got nothing: dropped SYNs, no grant")
expectEqual(cause(NSURLErrorBadURL, reply("general failure"), .milliseconds(120)), .proxyNotReady,
            "an instant refusal: the node is still settling")
expectEqual(cause(NSURLErrorBadURL, nil, .seconds(30)), .noAnswer,
            "with no reply on record, elapsed still decides")
expectEqual(cause(NSURLErrorBadURL, nil, .milliseconds(120)), .proxyNotReady,
            "...in both directions")
// The boundary itself, stated: at the threshold it is already "no answer".
expectEqual(cause(NSURLErrorBadURL, nil, PageFailureText.noAnswerThreshold), .noAnswer,
            "the threshold is inclusive")
expectEqual(cause(NSURLErrorBadURL, nil, PageFailureText.noAnswerThreshold - .milliseconds(1)),
            .proxyNotReady, "and just below it is not")

section("the other codes")
expectEqual(cause(NSURLErrorTimedOut), .timedOutAfterConnect, "-1001: connected, never answered")
expectEqual(cause(-1200), .certificate, "-1200 is the TLS family")
expectEqual(cause(-1206), .certificate, "-1206 too")
expectTrue(cause(-1199) != .certificate, "-1199 is not in the TLS family")
expectTrue(cause(-1207) != .certificate, "-1207 is not either")
expectEqual(cause(NSURLErrorCannotConnectToHost), .proxyDown,
            "-1004: WebKit dialled a dead proxy on this phone")
expectEqual(cause(NSURLErrorNotConnectedToInternet), .proxyDown,
            "-1009: the relay accepted, tsnet's port under it refused")
expectEqual(cause(42, nil, .seconds(1), domain: "WebKitErrorDomain"),
            .other(domain: "WebKitErrorDomain", code: 42),
            "a domain that is not NSURLErrorDomain passes through")
expectEqual(cause(-4242), .other(domain: NSURLErrorDomain, code: -4242),
            "an unrecognised NSURL code passes through")

// MARK: - The words

section("every cause produces three non-empty lines, and a title naming the host")
let everyCause: [PageState.Failure.Cause] = [
    .noAnswer, .refused, .unreachable, .proxyNotReady, .proxyDown, .timedOutAfterConnect,
    .certificate, .unknownHost("nope"), .ambiguousHost("box", ["box1", "box2"]),
    .redirectedAway("https://elsewhere.example"), .gatewayError(status: 502),
    .gatewayError(status: 500), .pageCrashed(times: 3, window: 60), .stopped, .badAddress,
    .other(domain: "WebKitErrorDomain", code: 102),
]
for c in everyCause {
    let l = PageFailureText.lines(for: failure(c))
    expectTrue(!l.title.isEmpty && !l.cause.isEmpty && !l.next.isEmpty,
               "\(c.logName): all three lines say something")
    expectTrue(!l.title.hasSuffix(" ") && !l.cause.hasSuffix(" "),
               "\(c.logName): no trailing space from an interpolation")
    // No case may leave a Swift value visible to the owner.
    for part in [l.title, l.cause, l.next] {
        expectTrue(!part.contains("Optional(") && !part.contains("nil"),
                   "\(c.logName): no Optional or nil leaks into the words: \(part)")
    }
}

section("a SOCKS failure reads as a connection problem, never a URL problem")
let noAnswer = PageFailureText.lines(for: failure(.noAnswer, elapsed: .seconds(31)))
expectEqual(noAnswer.title, "Couldn't reach byskebox", "the title names the host, not the error")
expectTrue(noAnswer.cause.contains("didn't answer on port 443 in 31 s"),
           "it says what happened and for how long: \(noAnswer.cause)")
expectTrue(noAnswer.cause.contains("isn't allowed to reach"),
           "and names the likely cause: no grant for this device")
expectTrue(noAnswer.next.contains("Settings → Status"),
           "and where to get the address the tailnet admin needs")
for part in [noAnswer.title, noAnswer.cause, noAnswer.next] {
    expectTrue(!part.lowercased().contains("url"),
               "the word URL appears nowhere in a connection failure: \(part)")
    expectTrue(!part.contains("-1000"), "nor the raw code, which belongs in Details")
}

section("the port appears in the title only when it is not 443 (F1)")
expectEqual(PageFailureText.displayHost("byskebox", port: 443), "byskebox", "443 is implied")
expectEqual(PageFailureText.displayHost("byskebox", port: 8443), "byskebox:8443", "8443 is shown")
expectTrue(PageFailureText.lines(for: failure(.refused, port: 8443)).title.contains("byskebox:8443"),
           "and the title carries it")
expectTrue(PageFailureText.lines(for: failure(.refused, port: 8443)).cause.contains("port 8443"),
           "as does the cause")

section("D10: serve's 5xx and Kiro Crew's own error do not read the same")
let down = PageFailureText.lines(for: failure(.gatewayError(status: 502)))
let broke = PageFailureText.lines(for: failure(.gatewayError(status: 500)))
expectTrue(down.cause.contains("Kiro Crew behind it didn't"),
           "502 blames what is behind the gateway, not the tailnet: \(down.cause)")
expectTrue(down.next.contains("few seconds"), "502 says a restart is normally over by then")
expectTrue(broke.cause.contains("running but couldn't serve it"),
           "500 blames Kiro Crew itself: \(broke.cause)")
expectTrue(down.title != broke.title && down.cause != broke.cause,
           "the two 5xx causes are told apart, which is their whole diagnostic value")
for status in [502, 503, 504] {
    expectTrue(PageFailureText.lines(for: failure(.gatewayError(status: status))).cause
                 .contains("Kiro Crew behind it didn't"),
               "\(status) is a serve-front failure")
}
expectTrue(!PageFailureText.lines(for: failure(.gatewayError(status: 418))).cause
             .contains("Kiro Crew behind it didn't"),
           "but an ordinary 4xx-shaped error is not")

section("badAddress is the ONE case that may talk about the address")
let bad = PageFailureText.lines(for: failure(.badAddress))
expectEqual(bad.title, "Latchkey can't open this address", "and it is reached only by a parse failure")

// MARK: - Details

section("Details carry the record, escaped, and never the token")
let d = PageFailureText.details(for: failure(.refused, proxyReply: reply("connection refused",
                                                                        after: .milliseconds(37))),
                               urlString: "https://byskebox.example.ts.net/a\u{A0}b")
expectTrue(d.contains { $0.contains("\\u{A0}") },
           "an invisible character is shown escaped: \(d)")
expectTrue(d.contains { $0.contains("connection refused after 37 ms") },
           "the relay's reply and its timing are kept: \(d)")
expectTrue(d.contains { $0.contains("NSURLErrorDomain") },
           "as is the raw domain and code")
let d502 = PageFailureText.details(for: failure(.gatewayError(status: 502), contentType: "",
                                               bodyLength: 0),
                                  urlString: "")
expectTrue(d502.contains { $0.contains("HTTP 502, Content-Type none, body 0 bytes") },
           "an empty 502 is described exactly, which is what serve sends: \(d502)")
expectTrue(!d502.contains { $0.contains("URL (escaped)") },
           "no empty URL row when there is no URL")

section("debugEscaped")
expectEqual(debugEscaped("https://ok.example/a b"), "https://ok.example/a b",
            "printable ASCII, space included, is left alone")
expectEqual(debugEscaped("a\u{200B}b"), "a\\u{200B}b", "a zero-width space is revealed")
expectEqual(debugEscaped("a%C2%A0b"), "a\\u{A0}b",
            "and a percent-encoded one is decoded first, then revealed")

// MARK: - PageState arithmetic

section("elapsed seconds floor, and never go backwards")
let t0 = ContinuousClock.now
expectEqual(PageState.elapsedSeconds(since: t0, now: t0), 0, "zero at the start")
expectEqual(PageState.elapsedSeconds(since: t0, now: t0 + .milliseconds(1900)), 1,
            "1.9 s floors to 1, so the number is never ahead of the clock")
expectEqual(PageState.elapsedSeconds(since: t0, now: t0 - .seconds(5)), 0,
            "a clock that appears to go backwards shows 0, not a negative")
expectEqual(PageState.milliseconds(.milliseconds(1234)), 1234, "milliseconds of a duration")
expectEqual(PageState.milliseconds(.seconds(2) + .milliseconds(5)), 2005, "...across the second")

section("the hint threshold")
expectTrue(!PageState.hintIsDue(since: t0, delay: .seconds(8), now: t0 + .seconds(7)),
           "not due at 7 s")
expectTrue(PageState.hintIsDue(since: t0, delay: .seconds(8), now: t0 + .seconds(8)),
           "due at exactly 8 s")
expectTrue(PageState.hintIsDue(since: t0, delay: .seconds(8), now: t0 + .seconds(9)), "and after")

section("describe: one line per state for Settings → Status → Page")
expectEqual(PageFailureText.describe(.idle), "idle", "idle")
expectEqual(PageFailureText.describe(.holding(host: "byskebox", since: t0), now: t0 + .seconds(3)),
            "waiting for the peer list before opening byskebox (3 s)", "holding names the wait")
expectEqual(PageFailureText.describe(.connecting(host: "byskebox", port: 8443, since: t0, attempt: 2),
                                     now: t0 + .seconds(9)),
            "connecting to byskebox:8443 (attempt 2, 9 s)", "connecting names the attempt")
expectEqual(PageFailureText.describe(.committed), "page shown", "committed")
expectEqual(PageFailureText.describe(.failed(failure(.gatewayError(status: 502),
                                                     elapsed: .seconds(1)))),
            "failed: gatewayError status=502 after 1 s", "failed names the cause and the status")

section("attaching a late relay reply upgrades the verdict")
// The relay publishes from its own queue and WebKit delivers from its own
// process; a reply that lands just after the failure must not be lost.
let bare = failure(cause(NSURLErrorBadURL, nil, .seconds(10)), elapsed: .seconds(10))
expectEqual(bare.cause, .noAnswer, "with no reply, a long -1000 reads as no answer")
let upgraded = bare.attaching(reply("connection refused"))
expectEqual(upgraded.cause, .refused, "the reply arriving late re-decides the cause")
expectEqual(upgraded.elapsed, bare.elapsed, "and changes nothing else")
expectEqual(upgraded.host, bare.host, "...including the host")

if failures == 0 {
    print("\n\(checks)/\(checks) page failure text checks passed")
} else {
    print("\n\(failures) of \(checks) page failure text checks FAILED")
    exit(1)
}
