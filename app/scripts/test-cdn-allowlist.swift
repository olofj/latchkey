// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

// Host-only tests of what the allow rules of App/Browser/ContentRules.swift
// MATCH (F6 §4.1, §4.1a), without WebKit: each emitted url-filter run as a
// case-insensitive regex, as WebKit's url-filter is by default. The L1 suite
// exercises one CDN host for real; the other three are the same shape, and
// this is where their anchoring is pinned: an exact host, https only, the
// default port only. The trailing `/` is the character that matters.
//
// Run:  make test-policy     (or: scripts/test-cdn-allowlist.sh)

import Foundation

var failures = 0
var checks = 0

func expect(_ cond: Bool, _ what: String) {
    checks += 1
    if cond { print("  ok   \(what)"); return }
    failures += 1
    print("  FAIL \(what)")
}

func section(_ name: String) { print("\n== \(name)") }

func filters(_ origin: String, _ cdn: Bool) -> [String] {
    guard let json = ContentRules.json(forOrigin: origin, allowCDNs: cdn),
          let rules = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]] else { return [] }
    return rules.compactMap { ($0["trigger"] as? [String: Any])?["url-filter"] as? String }
}

func matches(_ filter: String, _ url: String) -> Bool {
    guard let re = try? NSRegularExpression(pattern: filter, options: [.caseInsensitive]) else { return false }
    return re.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil
}

/// Does any rule of the list, other than a catch-all, admit `url`?
func admitted(_ fs: [String], _ url: String) -> Bool { fs.contains { $0 != ".*" && matches($0, url) } }

section("the set")
let hosts = ContentRules.allowedCDNHosts
expect(hosts == ["esm.sh", "cdn.jsdelivr.net", "cdnjs.cloudflare.com", "cdn.tailwindcss.com"],
       "exactly the four hosts of §4.1a, in order: \(hosts)")
expect(!hosts.contains("fonts.googleapis.com") && !hosts.contains("fonts.gstatic.com"), "neither font host")
expect(!hosts.contains { $0.contains("*") }, "no wildcard")

section("each CDN rule admits its host and nothing like it")
let gateway = "https://gw.example.ts.net:8443"
let on = filters(gateway, true)
for host in hosts {
    let own = on.filter { $0.contains(ContentRules.urlFilterEscaped(host)) }
    expect(own.count == 1, "\(host): one rule")
    guard let f = own.first else { continue }
    expect(matches(f, "https://\(host)/x"), "\(host): matches https://\(host)/x")
    expect(matches(f, "HTTPS://\(host.uppercased())/x"), "\(host): case-insensitive, like WebKit")
    for bad in ["https://\(host).evil.example/x", "https://\(host)evil.example/x", "https://\(host):8444/x",
                "http://\(host)/x", "https://sub.\(host)/x", "https://evil.example/https://\(host)/x"] {
        expect(!matches(f, bad), "\(host): not \(bad)")
        expect(!admitted(on, bad), "\(host): no rule in the list admits \(bad)")
    }
    expect(!admitted(filters(gateway, false), "https://\(host)/x"), "\(host): the strict list does not admit it")
}

section("the gateway rule admits its origin and nothing like it")
expect(admitted(on, "https://gw.example.ts.net:8443/x"), "https://gw.example.ts.net:8443/x")
expect(admitted(on, "wss://gw.example.ts.net:8443/api/ws"), "wss://gw.example.ts.net:8443/api/ws")
for bad in ["https://gw.example.ts.net:9999/x", "https://gw.example.ts.net/x", "https://gw.example.ts.net.evil.example/x",
            "https://gw.example.ts.net:8443.evil.example/x", "https://gwxexample.ts.net:8443/x",
            "http://gw.example.ts.net:8443/x", "wss://gw.example.ts.net/x"] {
    expect(!admitted(on, bad), "not \(bad)")
}
let unported = filters("https://gw.example.ts.net", true)
expect(admitted(unported, "https://gw.example.ts.net/x"), "unported: https://gw.example.ts.net/x")
for bad in ["https://gw.example.ts.net:8443/x", "https://gw.example.ts.net.evil.example/x"] {
    expect(!admitted(unported, bad), "unported: not \(bad)")
}

print("")
if failures == 0 {
    print("\(checks)/\(checks) CDN allowlist checks passed")
} else {
    print("\(failures) of \(checks) CDN allowlist checks FAILED")
    exit(1)
}
