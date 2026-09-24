// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

// Host-only tests for App/Browser/NavigationPolicy.swift (revision R3).
//
// Run:  make test-policy     (or: scripts/test-navigation-policy.sh)

import Foundation

var failures = 0
var checks = 0

func expect(_ url: String?, main: Bool = true, origin: String? = gateway,
            _ want: NavigationDecision, _ what: String) {
    checks += 1
    let got = NavigationPolicy.decide(url: url.flatMap(URL.init(string:)),
                                      isMainFrame: main, allowedOrigin: origin)
    if got != want {
        failures += 1
        print("  FAIL: \(what)\n        url: \(url ?? "nil")  main: \(main)  origin: \(origin ?? "nil")\n        got: \(got)  expected: \(want)")
    }
}

func section(_ name: String) { print("\n== \(name)") }

let gateway = "https://gateway.example.ts.net"

section("main frame: the gateway origin is allowed")
expect("https://gateway.example.ts.net/", .allow, "gateway root")
expect("https://gateway.example.ts.net/chat/abc?sid=1#m", .allow, "any path, query, fragment")
expect("https://gateway.example.ts.net/?token=abc", .allow, "a sign-in link to the gateway itself")
expect("https://GATEWAY.example.ts.net/", .allow, "host comparison is case-insensitive")
expect("https://gateway.example.ts.net:443/", .allow, "explicit default port is the same origin")

section("main frame: anything else leaves the app")
expect("https://github.com/kirodotdev/KiroCrew", .openExternally, "a public site")
expect("https://other.example.ts.net/", .openExternally, "another tailnet host")
expect("http://gateway.example.ts.net/", .openExternally, "same host, http: a different origin")
expect("https://gateway.example.ts.net:8443/", .openExternally, "same host, other port")
expect("https://gateway.example.ts.net.evil.example/", .openExternally, "suffix-extended look-alike")
expect("https://evil.example/gateway.example.ts.net", .openExternally, "gateway name in the path")
expect("https://gateway.example.ts.net@evil.example/", .openExternally, "gateway name as userinfo")
expect("mailto:someone@example.com", .openExternally, "mailto goes to the system")
expect("tel:+15555550123", .openExternally, "tel goes to the system")

section("main frame: never rendered, never handed on")
expect("data:text/html,<h1>session expired</h1>", .cancel, "a data: document (the phishing shape)")
expect("javascript:alert(1)", .cancel, "javascript: URL")
expect("file:///etc/passwd", .cancel, "file: URL")
expect(nil, .cancel, "no URL at all")

section("main frame: special cases")
expect("about:blank", .allow, "about:blank is the unreachable-gateway fallback")
expect("blob:https://gateway.example.ts.net/6f0c-uuid", .allow, "same-origin blob (a download)")
expect("blob:https://evil.example/6f0c-uuid", .cancel, "foreign blob")
expect("https://gateway.example.ts.net/", origin: nil, .openExternally,
       "nothing loaded yet: no web origin is trusted")

section("sub-frames are left alone")
expect("https://gateway.example.ts.net/sandbox-doc/w1", main: false, .allow, "same-origin widget iframe")
expect("https://www.youtube.com/embed/x", main: false, .allow, "cross-origin iframe cannot take over the view")
expect("about:srcdoc", main: false, .allow, "srcdoc iframe")

print("")
// MARK: - ResponsePolicy (F4 §4.13, state D10)
//
// The delegate used to .allow every response without looking, so a 502 from
// `tailscale serve` -- which is what a stopped Kiro Crew answers on a live
// port 443 -- committed its empty body as the document. No NSURLError is
// produced on that path, so nothing else in the app could notice.
print("== responses: which ones commit")

func expectTrue(_ got: Bool, _ what: String) {
    checks += 1
    if got { return }
    print("  FAIL: \(what)")
    failures += 1
}

func expectResponse(_ got: ResponseDecision, _ want: ResponseDecision, _ what: String) {
    checks += 1
    if got == want { return }
    print("  FAIL: \(what): got \(got), want \(want)")
    failures += 1
}

// The whole point: a gateway that is not there must not paint a blank page.
for status in [500, 502, 503, 504, 599] {
    expectResponse(ResponsePolicy.decide(isMainFrame: true, statusCode: status, authRequired: false),
                   .refuse, "a main-frame \(status) is refused")
}
// A gateway that answered gets to show its own page, however unhappily.
for status in [100, 200, 204, 301, 302, 304, 400, 401, 403, 404, 418, 499] {
    expectResponse(ResponsePolicy.decide(isMainFrame: true, statusCode: status, authRequired: false),
                   .commit, "a main-frame \(status) commits")
}
// KiroCrew's own voice is always shown. Refusing this would turn "that sign-in
// link didn't work" into "couldn't reach the gateway" -- blaming the tailnet
// for something the gateway said deliberately.
for status in [401, 403] {
    expectResponse(ResponsePolicy.decide(isMainFrame: true, statusCode: status, authRequired: true),
                   .commit, "\(status) with X-Auth-Required commits (sign-in must not break)")
}
expectResponse(ResponsePolicy.decide(isMainFrame: true, statusCode: 503, authRequired: true),
               .commit, "even a 5xx with X-Auth-Required commits, stated once")
// Sub-frames are the page's own business, like their requests.
for status in [500, 502, 503] {
    expectResponse(ResponsePolicy.decide(isMainFrame: false, statusCode: status, authRequired: false),
                   .commit, "a sub-frame \(status) is left alone")
}
// Nothing to inspect: about:blank, a scheme handler, a blob.
expectResponse(ResponsePolicy.decide(isMainFrame: true, statusCode: nil, authRequired: false),
               .commit, "a non-HTTP response commits")

print("== responses: the wording tells a stopped gateway from a broken one")
let downText = ResponsePolicy.refusalText(status: 502, host: "gw.example.ts.net")
expectTrue(downText.contains("isn't running") && downText.contains("gw.example.ts.net")
       && downText.contains("502"), "502 names the host, the status, and says Kiro Crew is not running")
expectTrue(downText.lowercased().contains("tailnet and the gateway are fine"),
       "502 says the tailnet is not the problem: that is the whole diagnostic value")
let brokeText = ResponsePolicy.refusalText(status: 500, host: "gw.example.ts.net")
expectTrue(brokeText.contains("failed to build the page"),
       "500 blames Kiro Crew itself, not the serve front")
expectTrue(downText != brokeText, "the two 5xx causes do not read the same")

if failures == 0 {
    print("\(checks)/\(checks) navigation policy checks passed")
} else {
    print("\(failures) of \(checks) navigation policy checks FAILED")
    exit(1)
}
