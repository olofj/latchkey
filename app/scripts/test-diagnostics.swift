// Host tests for App/Diagnostics/NodeLog.swift, Expiry.swift and
// SessionCookies.swift (M8.2, M8.3, R31, R33).
import Foundation

var failures = 0
var checks = 0
func expect(_ cond: Bool, _ what: String) {
    checks += 1
    if !cond { failures += 1; print("  FAIL \(what)") }
}

print("== NodeLog")
let dir = FileManager.default.temporaryDirectory.appending(path: "kr-nodelog-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
expect(NodeLog.tail(in: dir).isEmpty, "no files: no lines")
try! "2026-09-21T10:00:00.000Z old one\n2026-09-21T10:00:01.000Z old two\n".write(
    to: dir.appending(path: "tsnet.log.1"), atomically: true, encoding: .utf8)
try! ("2026-09-21T10:00:02.000Z magicsock: new one\n"
      + "2026-09-21T10:00:03.000Z go to: https://login.tailscale.com/a/4653479012c06\n").write(
    to: dir.appending(path: "tsnet.log"), atomically: true, encoding: .utf8)
let all = NodeLog.tail(in: dir)
expect(all.count == 4, "both files read: \(all.count)")
expect(all.first?.hasSuffix("old one") == true && all.last?.contains("login.tailscale.com") == true,
       "oldest first: the rotated file, then the current one")
expect(!all.joined().contains("4653479012c06"), "a login code in tsnet's output is redacted on the way out")
expect(NodeLog.tail(in: dir, maxLines: 2) == Array(all.suffix(2)), "tail keeps the newest lines")
expect(NodeLog.tail(in: dir, source: .stderr).isEmpty, "the stderr log is its own file")
try! "2026-09-21T10:00:04.000Z panic: runtime error\n".write(
    to: dir.appending(path: "stderr.log"), atomically: true, encoding: .utf8)
expect(NodeLog.tail(in: dir, source: .stderr) == ["2026-09-21T10:00:04.000Z panic: runtime error"]
       && NodeLog.tail(in: dir).count == 4, "each source reads only its own files")

print("== key expiry")
let k1 = Expiry.parseKeyExpiry("2026-12-20T11:22:33Z")
let k2 = Expiry.parseKeyExpiry("2026-12-20T11:22:33.123456789Z")
expect(k1 != nil && k2 != nil, "RFC 3339 with and without fractional seconds")
expect(Expiry.parseKeyExpiry(nil) == nil && Expiry.parseKeyExpiry("") == nil && Expiry.parseKeyExpiry("soon") == nil,
       "absent (expiry disabled) or garbage: nil")

print("== provisioning profile")
let plist = """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>ExpirationDate</key><date>2026-09-28T09:00:00Z</date><key>Name</key><string>x</string></dict></plist>
"""
var blob = Data([0x30, 0x82, 0x01, 0x02, 0x06, 0x09])   // a DER prefix, as in a real CMS wrapper
blob.append(Data(plist.utf8))
blob.append(Data([0xA0, 0x82, 0x00, 0x10]))
let pe = Expiry.profileExpiration(blob)
expect(pe != nil && abs(pe!.timeIntervalSince(ISO8601DateFormatter().date(from: "2026-09-28T09:00:00Z")!)) < 1,
       "ExpirationDate read out of the signed wrapper")
expect(Expiry.profileExpiration(Data("no plist here".utf8)) == nil, "no plist: nil")

print("== warnings")
let now = ISO8601DateFormatter().date(from: "2026-09-21T09:00:00Z")!
expect(Expiry.warnings(keyExpiry: now.addingTimeInterval(30 * 86400), profileExpiry: now.addingTimeInterval(5 * 86400), now: now).isEmpty,
       "30 days of key, 5 days of profile: nothing yet")
expect(Expiry.warnings(keyExpiry: now.addingTimeInterval(10 * 86400), profileExpiry: nil, now: now) == [.key(expiresIn: 10 * 86400)],
       "key inside 14 days: warn")
expect(Expiry.warnings(keyExpiry: nil, profileExpiry: now.addingTimeInterval(47 * 3600), now: now) == [.profile(expiresIn: 47 * 3600)],
       "profile inside 48 hours: warn")
expect(Expiry.warnings(keyExpiry: now.addingTimeInterval(-1), profileExpiry: now.addingTimeInterval(3600), now: now)
       == [.profile(expiresIn: 3600), .keyExpired], "most urgent first: the profile, then the expired key")
expect(Expiry.describe(3 * 86400 + 5) == "3 days" && Expiry.describe(5 * 3600) == "5 hours"
       && Expiry.describe(90 * 60) == "an hour" && Expiry.describe(600) == "under an hour", "human durations")
expect(!Expiry.message(.key(expiresIn: 86400 * 3)).isEmpty, "every warning has a message")

print("== session cookies")
func cookie(_ name: String, _ domain: String, expires: Date?, path: String = "/") -> HTTPCookie {
    var p: [HTTPCookiePropertyKey: Any] = [.name: name, .value: "SECRET-\(name)", .domain: domain, .path: path]
    if let expires { p[.expires] = expires }
    return HTTPCookie(properties: p)!
}
let gw = "gw.tail-scale.ts.net"
let jar = [
    cookie("mc_token_443", gw, expires: now.addingTimeInterval(3600)),
    cookie("mc_refresh_443", gw, expires: now.addingTimeInterval(30 * 86400), path: "/api/auth"),
    cookie("mc_refresh_443", "other.tail-scale.ts.net", expires: now.addingTimeInterval(90 * 86400), path: "/api/auth"),
    cookie("unrelated", gw, expires: now.addingTimeInterval(99 * 86400)),
]
let sum = SessionCookies.summary(of: jar, host: gw)
expect(sum.access == .expires(now.addingTimeInterval(3600)), "access cookie expiry: \(sum.access)")
expect(sum.refresh == .expires(now.addingTimeInterval(30 * 86400)),
       "refresh cookie expiry, and another gateway's cookie is not this one's: \(sum.refresh)")
expect(SessionCookies.summary(of: jar, host: "") == SessionCookies.Summary(), "no gateway: no session")
expect(SessionCookies.summary(of: [cookie("mc_token_443", gw, expires: nil)], host: gw).access == .untilQuit,
       "a cookie without an expiry lasts until the app quits")
expect(SessionCookies.summary(of: [cookie("mc_token_443", ".tail-scale.ts.net", expires: now)], host: gw).access == .expires(now),
       "a domain cookie covers the gateway")
expect(!SessionCookies.matches(domain: ".ts.net", host: "ts.net.evil") && !SessionCookies.matches(domain: "w.tail-scale.ts.net", host: gw),
       "no suffix confusion")
let shown = [SessionCookies.describe(sum.access, now: now), SessionCookies.describe(sum.refresh, now: now),
             SessionCookies.describe(.none, now: now), SessionCookies.describe(.expires(now.addingTimeInterval(-60)), now: now)]
expect(shown[0].hasSuffix("(in an hour)") && shown[1].hasSuffix("(in 30 days)") && shown[2] == "none" && shown[3].hasPrefix("expired"),
       "described: \(shown)")
expect(!shown.joined().contains("SECRET"), "a cookie's value is never shown")

print(failures == 0 ? "\(checks)/\(checks) diagnostics checks passed" : "\(failures) of \(checks) diagnostics checks FAILED")
exit(failures == 0 ? 0 : 1)
