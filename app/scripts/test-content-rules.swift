// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

// Host-only tests for App/Browser/ContentRules.swift (F6 §4.1, §4.1a).
//
// The shape of the list, then the exact JSON compiled by macOS WebKit's own
// rule compiler, so a bad escape or a misspelled type fails here rather than
// on the phone. The compiler is shown able to refuse: the
// -UITestBreakContentRules payload must not compile.
//
// Run:  make test-policy     (or: scripts/test-content-rules.sh)

import Foundation
import WebKit

var failures = 0
var checks = 0

func expect(_ cond: Bool, _ what: String, _ detail: @autoclosure () -> String = "") {
    checks += 1
    if cond { print("  ok   \(what)"); return }
    failures += 1
    let d = detail()
    print("  FAIL \(what)" + (d.isEmpty ? "" : "\n       \(d)"))
}

func section(_ name: String) { print("\n== \(name)") }

typealias Rule = [String: Any]

func rules(_ origin: String, _ cdn: Bool) -> [Rule] {
    guard let json = ContentRules.json(forOrigin: origin, allowCDNs: cdn),
          let parsed = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [Rule] else { return [] }
    return parsed
}
func filter(_ r: Rule) -> String? { (r["trigger"] as? [String: Any])?["url-filter"] as? String }
func action(_ r: Rule) -> String? { (r["action"] as? [String: Any])?["type"] as? String }
func types(_ r: Rule) -> [String]? { (r["trigger"] as? [String: Any])?["resource-type"] as? [String] }
func filters(_ rs: [Rule]) -> [String] { rs.compactMap(filter) }

let unported = "https://gw.example.ts.net"
let ported = "https://gw.example.ts.net:8443"
let ipv6 = "https://[fd7a:115c:a1e0::1]:8443"
let plain = "http://gw.example.ts.net:8080"

section("the gateway's origin, exactly")
for (origin, want) in [(unported, #"gw\.example\.ts\.net"#), (ported, #"gw\.example\.ts\.net:8443"#),
                       (ipv6, #"\[fd7a:115c:a1e0::1]:8443"#)] {
    for cdn in [true, false] {
        let f = filters(rules(origin, cdn))
        expect(f.contains("^https://\(want)/"), "\(origin) cdn\(cdn ? 1 : 0): https rule ^https://\(want)/", "\(f)")
        expect(f.contains("^wss://\(want)/"), "\(origin) cdn\(cdn ? 1 : 0): wss rule ^wss://\(want)/", "\(f)")
    }
}
let rawUnported = ContentRules.json(forOrigin: unported, allowCDNs: true) ?? ""
expect(rawUnported.contains(#"gw\\.example\\.ts\\.net/"#), "`.` is escaped, and the backslash doubled in JSON", rawUnported)
expect(!filters(rules(unported, true)).contains { $0.contains(":8443") }, "no port in the unported origin's rules")
expect(!filters(rules(ported, true)).contains("^https://gw\\.example\\.ts\\.net/"),
       "the ported origin does not also allow the default port")
let fPlain = filters(rules(plain, true))
expect(fPlain.contains(#"^http://gw\.example\.ts\.net:8080/"#) && fPlain.contains(#"^ws://gw\.example\.ts\.net:8080/"#),
       "http:// yields ws://", "\(fPlain)")
expect(!fPlain.contains { $0.hasPrefix("^wss://") || $0.hasPrefix("^https://gw") }, "and not wss:// or https://")
expect(ContentRules.urlFilterEscaped(#"\{}[.?*$]/:-a"#) == #"\\\{\}\[\.\?\*\$]/:-a"#,
       #"escapes exactly \ { } [ . ? * $; leaves ] / : - literal"#, ContentRules.urlFilterEscaped(#"\{}[.?*$]/:-a"#))

section("not an http(s) origin: no rules")
for bad in ["ftp://gw.example.ts.net", "gw.example.ts.net", "https://", "https://gw.example.ts.net/",
            "https://gw.example.ts.net/x", "https://gw.example.ts.net?x", "https://gw.example.ts.net#x", ""] {
    expect(ContentRules.json(forOrigin: bad, allowCDNs: true) == nil
           && ContentRules.json(forOrigin: bad, allowCDNs: false) == nil, "\"\(bad)\" → nil")
}

section("identifier carries the version, the CDN flag and the origin")
for cdn in [true, false] {
    let id = ContentRules.identifier(forOrigin: ported, allowCDNs: cdn)
    expect(id == "\(ContentRules.identifierPrefix)v\(ContentRules.schemaVersion).cdn\(cdn ? 1 : 0).\(ported)",
           "identifier \(id)")
    expect(id.hasPrefix("latchkey.single-origin."), "starts with the prefix old lists are found by")
}
expect(ContentRules.identifier(forOrigin: ported, allowCDNs: true)
       != ContentRules.identifier(forOrigin: ported, allowCDNs: false), "the two CDN settings never share a name")
expect(ContentRules.identifier(forOrigin: unported, allowCDNs: true)
       != ContentRules.identifier(forOrigin: ported, allowCDNs: true), "two origins never share a name")

section("the list's shape")
for origin in [unported, ported] {
    let on = rules(origin, true), off = rules(origin, false)
    expect(on.count == 10, "\(origin): 10 rules with the allowlist", "\(on.count)")
    expect(off.count == 6, "\(origin): 6 rules without it", "\(off.count)")
    for (rs, n) in [(on, 1), (off, 0)] {
        guard let first = rs.first else { expect(false, "\(origin) cdn\(n): parses"); continue }
        expect(filter(first) == ".*" && action(first) == "block" && types(first) == nil
               && (first["trigger"] as? [String: Any])?.count == 1,
               "\(origin) cdn\(n): rule 1 blocks .* with no resource-type and no condition")
        expect(rs.dropFirst().allSatisfy { action($0) == "ignore-previous-rules" },
               "\(origin) cdn\(n): every later rule is ignore-previous-rules")
        let exempt = rs.firstIndex { types($0) != nil }
        expect(exempt.map { i in filter(rs[i]) == ".*" && types(rs[i]) == ["top-document", "popup"] } == true
               && exempt == (n == 1 ? 5 : 1) && rs.filter { types($0) != nil }.count == 1,
               "\(origin) cdn\(n): top-document/popup exempt, right after the allowlist")
        expect(filters(rs).suffix(2) == ["^blob:", "^about:"], "\(origin) cdn\(n): blob: and about: last")
    }
    let cdn = filters(Array(on[1...4]))
    let want = ContentRules.allowedCDNHosts.map { "^https://" + ContentRules.urlFilterEscaped($0) + "/" }
    expect(cdn == want, "\(origin): the four CDN entries follow rule 1, in allowedCDNHosts order", "\(cdn)")
    expect(cdn.allSatisfy { $0.hasPrefix("^https://") && $0.hasSuffix("/") }, "\(origin): each anchored ^https:// and ending /")
    expect(!ContentRules.allowedCDNHosts.contains { h in filters(off).contains { $0.contains(ContentRules.urlFilterEscaped(h)) } },
           "\(origin): no CDN host in the strict list")
}

section("macOS WebKit compiles the exact JSON")
let storeDir = FileManager.default.temporaryDirectory.appending(path: "content-rules-tests-\(getpid())")
try? FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)

/// nil: compiled. Otherwise WebKit's error, or why there was no answer.
@MainActor func compile(_ id: String, _ json: String) -> String? {
    guard let store = WKContentRuleListStore(url: storeDir) else { return "WKContentRuleListStore(url:) returned nil" }
    var result: String?? = nil
    store.compileContentRuleList(forIdentifier: id, encodedContentRuleList: json) { list, err in
        result = .some(err.map { "\(($0 as NSError).userInfo[NSHelpAnchorErrorKey] ?? $0)" }
                       ?? (list == nil ? "no list and no error" : nil))
    }
    let deadline = Date.now + 30
    while result == nil && Date.now < deadline { RunLoop.main.run(mode: .default, before: .now + 0.05) }
    return result ?? "no answer from the compiler in 30 s"
}

MainActor.assumeIsolated {
    for origin in [unported, ported, ipv6, plain] {
        for cdn in [true, false] {
            let id = ContentRules.identifier(forOrigin: origin, allowCDNs: cdn)
            guard let json = ContentRules.json(forOrigin: origin, allowCDNs: cdn) else {
                expect(false, "\(id): has a list"); continue
            }
            let err = compile(id, json)
            expect(err == nil, "\(id) compiles", err ?? "")
        }
    }
    let err = compile("latchkey.broken", ContentRules.brokenJSON)
    expect(err != nil && !err!.contains("returned nil") && !err!.contains("no answer"),
           "brokenJSON does not compile (so the checks above are not vacuous)", err ?? "it compiled")
}
try? FileManager.default.removeItem(at: storeDir)

print("")
if failures == 0 {
    print("\(checks)/\(checks) content rule checks passed")
} else {
    print("\(failures) of \(checks) content rule checks FAILED")
    exit(1)
}
