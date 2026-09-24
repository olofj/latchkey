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
if failures == 0 {
    print("\(checks)/\(checks) navigation policy checks passed")
} else {
    print("\(failures) of \(checks) navigation policy checks FAILED")
    exit(1)
}
