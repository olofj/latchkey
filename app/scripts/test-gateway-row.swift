// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

// Host-only tests for App/Browser/GatewayChipState.swift (F22 §4).
//
// Run:  make test-policy     (or: scripts/test-gateway-row.sh)

import Foundation

var failures = 0
var checks = 0

func expect(_ cond: Bool, _ what: String) {
    checks += 1
    if !cond { failures += 1; print("  FAIL: \(what)") }
}

func section(_ name: String) { print("\n== \(name)") }

typealias S = GatewayChipState

func state(_ s: S, _ light: S.Light, _ word: String, _ tappable: Bool, _ what: String) {
    expect(s.light == light, "\(what): light \(s.light), want \(light)")
    expect(s.word == word, "\(what): word '\(s.word)', want '\(word)'")
    expect(s.tappable == tappable, "\(what): tappable \(s.tappable), want \(tappable)")
}

section("the chip in use follows its page")
state(.current(.committed), .ok, "connected", false, "committed")
state(.current(.connecting), .warn, "connecting", false, "connecting")
state(.current(.failed), .danger, "failed", false, "failed")
state(.current(.idle), .muted, "", false, "idle")

section("another gateway follows its probe")
state(.other(ready: false, carried: true, verdict: .answering), .muted, "tailnet not connected", false,
      "tailnet down beats a stale green")
state(.other(ready: true, carried: false, verdict: .answering), .muted, "not on this tailnet", false,
      "not carried is never tappable")
state(.other(ready: true, carried: true, verdict: .answering), .ok, "answering", true, "answering")
state(.other(ready: true, carried: true, verdict: .checking), .warn, "checking", true, "checking")
state(.other(ready: true, carried: true, verdict: nil), .warn, "checking", true, "no verdict yet")
state(.other(ready: true, carried: true, verdict: .notGateway), .danger, "not KiroCrew", true,
      "not a gateway is red, still tappable")
state(.other(ready: true, carried: true, verdict: .notAnswering), .danger, "not answering", true,
      "not answering is red, still tappable")

section("names")
expect(S.shortName("https://mac-studio.tail1234.ts.net") == "mac-studio", "first label on 443")
expect(S.shortName("https://mac-studio.tail1234.ts.net:8443") == "mac-studio:8443", "port off 443")
expect(S.shortName("https://gw.tail-scale.ts.net:443") == "gw", "an explicit 443 is not shown")
expect(S.shown("https://gw.tail-scale.ts.net:8443") == "gw.tail-scale.ts.net:8443", "shown keeps the port")

section("order")
let a = "https://a.ts.net", b = "https://b.ts.net", c = "https://c.ts.net:8443"
expect(S.order(current: a, known: [a]) == [], "one gateway: no row")
expect(S.order(current: a, known: []) == [], "nothing known: no row")
expect(S.order(current: "", known: [a, b]) == [], "no gateway in use: no row")
expect(S.order(current: b, known: [a, b, c]) == [b, a, c], "in use first, then as remembered")
expect(S.order(current: a, known: [b, b, c]) == [a, b, c], "each once")
expect(S.order(current: c, known: [a]) == [c, a], "in use even if not remembered")

print("\n\(checks - failures)/\(checks) checks passed")
exit(failures == 0 ? 0 : 1)
