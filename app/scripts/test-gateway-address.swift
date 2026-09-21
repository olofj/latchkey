// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

// Host-only tests for App/Browser/GatewayAddress.swift (revision R2).
//
// Run:  make test-policy     (or: scripts/test-gateway-address.sh)

import Foundation

var failures = 0
var checks = 0

func expectEqual<T: Equatable>(_ got: T, _ want: T, _ what: String) {
    checks += 1
    if got != want {
        failures += 1
        print("  FAIL: \(what)\n        got:      \(got)\n        expected: \(want)")
    }
}

func section(_ name: String) { print("\n== \(name)") }

let token = "eyJhbGciOiJIUzI1NiJ9.SECRET.sig"

section("stripParameters never keeps a query or fragment")
expectEqual(GatewayAddress.stripParameters("https://byskebox.example.ts.net/?token=\(token)"),
            "https://byskebox.example.ts.net/", "a pasted sign-in URL loses its token")
expectEqual(GatewayAddress.stripParameters("https://h.example/p#token=\(token)"),
            "https://h.example/p", "fragment is cut too")
expectEqual(GatewayAddress.stripParameters("byske"), "byske", "partial input is untouched")
expectEqual(GatewayAddress.stripParameters(""), "", "empty stays empty")
expectEqual(GatewayAddress.stripParameters("?token=\(token)"), "", "a bare query is dropped entirely")

section("origin reduces to scheme://host[:port]")
expectEqual(GatewayAddress.origin(of: "https://byskebox.example.ts.net"),
            "https://byskebox.example.ts.net", "an origin is unchanged")
expectEqual(GatewayAddress.origin(of: "https://byskebox.example.ts.net/?token=\(token)"),
            "https://byskebox.example.ts.net", "sign-in URL reduces to its origin")
expectEqual(GatewayAddress.origin(of: "https://byskebox.example.ts.net/chat/abc?sid=1"),
            "https://byskebox.example.ts.net", "path is dropped as well")
expectEqual(GatewayAddress.origin(of: "HTTPS://ByskeBox.example.ts.net/"),
            "https://byskebox.example.ts.net", "scheme and host are lowercased")
expectEqual(GatewayAddress.origin(of: "https://h.example:443/"), "https://h.example",
            "default https port is dropped")
expectEqual(GatewayAddress.origin(of: "http://h.example:80/"), "http://h.example",
            "default http port is dropped")
expectEqual(GatewayAddress.origin(of: "https://h.example:8443/x"), "https://h.example:8443",
            "a non-default port is kept")
expectEqual(GatewayAddress.origin(of: "https://user:pw@h.example/"), "https://h.example",
            "userinfo is dropped")
expectEqual(GatewayAddress.origin(of: "byskebox"), nil, "no scheme: not an origin")
expectEqual(GatewayAddress.origin(of: "ftp://h.example"), nil, "non-http scheme: not an origin")
expectEqual(GatewayAddress.origin(of: "https://"), nil, "no host: not an origin")

section("persistable is what reaches workspaces.json")
expectEqual(GatewayAddress.persistable("https://byskebox.example.ts.net/?token=\(token)"),
            "https://byskebox.example.ts.net", "token URL persists as its origin")
expectEqual(GatewayAddress.persistable("byskebox?token=\(token)"), "byskebox",
            "a non-URL still never persists a token")
expectEqual(GatewayAddress.persistable("http://byskebox"), "http://byskebox",
            "a bare-name URL keeps its host")

print("")
if failures == 0 {
    print("\(checks)/\(checks) gateway address checks passed")
} else {
    print("\(failures) of \(checks) gateway address checks FAILED")
    exit(1)
}
