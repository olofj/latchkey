// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

// Host-only tests for App/Network/ProxyConfigurationFactory.swift (R12).
//
// Asserts on the ProxyConfiguration objects the app itself builds, compiled
// together with the real TSNet/TailnetProxyPolicy.swift (against the same
// TailscaleKit stubs test-proxy-policy.sh uses).
//
// Run:  make test-policy     (or: scripts/test-proxy-config.sh)

import Foundation
import Network

var failures = 0
var checks = 0

func expect(_ cond: Bool, _ what: String) {
    checks += 1
    if !cond { failures += 1; print("  FAIL: \(what)") }
}

func section(_ name: String) { print("\n== \(name)") }

func status(suffix: String?, peers: [(String, String)]) -> IpnState.Status {
    var s = IpnState.Status()
    if let suffix { s.CurrentTailnet = IpnState.TailnetStatus(MagicDNSSuffix: suffix) }
    var map: [String: IpnState.PeerStatus] = [:]
    for (i, p) in peers.enumerated() {
        map["peer\(i)"] = IpnState.PeerStatus(HostName: p.0, DNSName: p.1)
    }
    s.Peer = map
    return s
}

let tailnet = status(suffix: "tail-scale.ts.net",
                     peers: [("dash", "dash.tail-scale.ts.net.")])
let split = TailnetProxyPolicy.make(from: tailnet)
let everything = TailnetProxyPolicy.make(from: tailnet, exitNodeEnabled: true)

section("the anti-leak property is the app's own, not a default")
let config = ProxyConfigurationFactory.make(proxyHost: "127.0.0.1", proxyPort: 50123,
                                            credential: "s3cret", policy: split)
expect(config != nil, "a valid endpoint builds a configuration")
expect(config?.allowFailover == false,
       "allowFailover is false on the configuration the app builds (a dead proxy must fail, not leak)")

section("split tunnel scoping")
expect(config?.matchDomains == split.matchDomains, "matchDomains is exactly the policy's rule set")
expect(!(config?.matchDomains.isEmpty ?? true),
       "split tunnel never produces an empty list (empty means proxy EVERYTHING)")
expect(config?.matchDomains.contains("100.64.0.0/10") ?? false, "tailnet IPv4 range is proxied")
expect(config?.matchDomains.contains("tail-scale.ts.net") ?? false, "MagicDNS suffix is proxied")
expect(!(config?.matchDomains.contains("") ?? true), "no empty-string rule (it matches everything)")

section("proxy-everything mode (test hook only)")
let all = ProxyConfigurationFactory.make(proxyHost: "127.0.0.1", proxyPort: 50123,
                                         credential: "s3cret", policy: everything)
expect(all?.matchDomains.isEmpty ?? false, "proxy-everything yields the empty (match-all) list")
expect(all?.allowFailover == false, "allowFailover stays false in proxy-everything mode too")

section("ProxyConfiguration aliases on copy; the factory never shares")
// Premise: a "copy" of a ProxyConfiguration shares its underlying object. If
// this ever stops being true the factory's caution is unnecessary, but the
// test must say so rather than quietly pass.
if let original = ProxyConfigurationFactory.make(proxyHost: "127.0.0.1", proxyPort: 50123,
                                                  credential: "s3cret", policy: split) {
    var copy = original
    copy.matchDomains = ["changed.example"]
    expect(original.matchDomains == ["changed.example"],
           "premise: mutating a copy mutates the original (reference semantics under a struct)")
} else {
    expect(false, "precondition: config built")
}
// So a rescope must be a new object: editing the new one leaves the old,
// possibly already installed in WebKit, untouched.
if let installed = ProxyConfigurationFactory.make(proxyHost: "127.0.0.1", proxyPort: 50123,
                                                   credential: "s3cret", policy: split),
   var rescoped = ProxyConfigurationFactory.make(proxyHost: "127.0.0.1", proxyPort: 50123,
                                                  credential: "s3cret", policy: everything) {
    rescoped.allowFailover = true
    rescoped.matchDomains = ["tampered.example"]
    expect(installed.allowFailover == false, "two factory results are independent objects (failover)")
    expect(installed.matchDomains == split.matchDomains, "two factory results are independent objects (rules)")
} else {
    expect(false, "precondition: configs built")
}

section("invalid endpoints")
expect(ProxyConfigurationFactory.make(proxyHost: "127.0.0.1", proxyPort: 0,
                                      credential: "x", policy: split) == nil, "port 0 is refused")
expect(ProxyConfigurationFactory.make(proxyHost: "127.0.0.1", proxyPort: 70_000,
                                      credential: "x", policy: split) == nil, "port above 65535 is refused")
expect(ProxyConfigurationFactory.make(proxyHost: "127.0.0.1", proxyPort: -1,
                                      credential: "x", policy: split) == nil, "negative port is refused")

print("")
if failures == 0 {
    print("\(checks)/\(checks) proxy configuration checks passed")
} else {
    print("\(failures) of \(checks) proxy configuration checks FAILED")
    exit(1)
}
