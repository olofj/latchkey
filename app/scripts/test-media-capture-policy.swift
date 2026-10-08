// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

// Host-only tests for App/Browser/MediaCapturePolicy.swift (F23 W2, T0).
//
// Run:  make test-policy     (or: scripts/test-media-capture-policy.sh)

import Foundation

var failures = 0
var checks = 0

let gateway = "https://gateway.example.ts.net"

func expect(_ kind: MediaCaptureKind = .microphone, main: Bool = true,
            origin: String?, allowed: String? = gateway,
            _ want: MediaCaptureDecision, _ what: String) {
    checks += 1
    let got = MediaCapturePolicy.decide(kind: kind, isMainFrame: main,
                                        origin: origin, allowedOrigin: allowed)
    if got != want {
        failures += 1
        print("  FAIL: \(what)\n        kind: \(kind)  main: \(main)  origin: \(origin ?? "nil")  allowed: \(allowed ?? "nil")\n        got: \(got)  expected: \(want)")
    }
}

func expectOrigin(_ scheme: String, _ host: String, _ port: Int, _ want: String?, _ what: String) {
    checks += 1
    let got = MediaCapturePolicy.origin(scheme: scheme, host: host, port: port)
    if got != want {
        failures += 1
        print("  FAIL: \(what)\n        got: \(got ?? "nil")  expected: \(want ?? "nil")")
    }
}

print("== granted: the dashboard's own mic request")
expect(origin: gateway, .grant, "mic, main frame, gateway origin")
expect(origin: "http://gateway.local:8080", allowed: "http://gateway.local:8080", .grant,
       "a ported http gateway, same port")

print("== denied: anything else")
expect(.camera, origin: gateway, .deny, "camera, even from the gateway")
expect(.cameraAndMicrophone, origin: gateway, .deny, "camera and mic together")
expect(.other, origin: gateway, .deny, "an unknown capture type")
expect(main: false, origin: gateway, .deny, "a subframe on the gateway origin (srcdoc widget)")
expect(origin: "https://other.example.ts.net", .deny, "another host")
expect(origin: "https://gateway.example.ts.net:8443", .deny, "same host, other port")
expect(origin: "http://gateway.example.ts.net", .deny, "same host, http instead of https")
expect(origin: "https://gateway.example.ts.net.evil.example", .deny, "suffix look-alike")
expect(origin: nil, .deny, "a request with no origin")
expect(origin: gateway, allowed: nil, .deny, "no allowed origin (error page, mid-switch)")
expect(origin: nil, allowed: nil, .deny, "neither origin (nil must not equal nil)")
expect(origin: "http://gateway.local", allowed: "http://gateway.local:8080", .deny,
       "the port is part of the comparison")

print("== origins: WebKit's parts render as GatewayAddress renders a URL")
expectOrigin("https", "gateway.example.ts.net", 0, gateway, "port 0 means the default")
expectOrigin("https", "gateway.example.ts.net", 443, gateway, "explicit default port dropped")
expectOrigin("HTTPS", "Gateway.Example.TS.net", 0, gateway, "case folded")
expectOrigin("http", "gateway.local", 8080, "http://gateway.local:8080", "a non-default port kept")
expectOrigin("http", "gateway.local", 80, "http://gateway.local", "http's default port dropped")
expectOrigin("about", "", 0, nil, "no http(s) origin (about:srcdoc, opaque)")
expectOrigin("https", "", 0, nil, "no host")

if failures == 0 {
    print("\(checks)/\(checks) media capture policy checks passed")
} else {
    print("\(failures) of \(checks) media capture policy checks FAILED")
    exit(1)
}
