// Host tests for App/Discovery/GatewayCandidates.swift (M5, R26).
import Foundation

var failures = 0
var checks = 0
func expect(_ cond: Bool, _ what: String) {
    checks += 1
    if !cond { failures += 1; print("  FAIL \(what)") }
}
func peer(_ host: String, online: Bool = true, expired: Bool = false, sharee: Bool = false,
          os: String? = "linux", user: Int64? = 7) -> GatewayPeer {
    GatewayPeer(host: host, online: online, expired: expired, sharee: sharee, os: os, userID: user)
}
func hosts(_ ps: [GatewayPeer]) -> [String] { ps.map(\.host) }

print("== filters")
expect(GatewayCandidates.exclusion(peer("a.ts.net"), selfUserID: 7) == nil, "an online linux peer of mine is a candidate")
expect(GatewayCandidates.exclusion(peer("a.ts.net", online: false), selfUserID: 7) == "offline", "offline is excluded")
expect(GatewayCandidates.exclusion(peer("a.ts.net", expired: true), selfUserID: 7) == "key expired", "expired is excluded")
expect(GatewayCandidates.exclusion(peer("a.ts.net", sharee: true), selfUserID: 7) != nil, "a sharee node is excluded")
expect(GatewayCandidates.exclusion(peer("a.ts.net", os: "iOS"), selfUserID: 7) != nil, "a phone is excluded")
expect(GatewayCandidates.exclusion(peer("a.ts.net", os: "android"), selfUserID: 7) != nil, "android is excluded")
for os in ["linux", "macOS", "windows", "MACOS"] {
    expect(GatewayCandidates.exclusion(peer("a.ts.net", os: os), selfUserID: 7) == nil, "\(os) is a server OS")
}
expect(GatewayCandidates.exclusion(peer("a.ts.net", user: 8), selfUserID: 7) == "another owner", "another owner is excluded")
expect(GatewayCandidates.exclusion(peer("a.ts.net", os: nil, user: nil), selfUserID: 7) == nil,
       "unknown OS and owner do not exclude")
expect(GatewayCandidates.exclusion(peer("a.ts.net", user: 8), selfUserID: nil) == nil,
       "no owner filter when this node's owner is unknown")
// What the status JSON actually carries for "unknown" (M5 review).
expect(GatewayCandidates.exclusion(peer("a.ts.net", os: ""), selfUserID: 7) == nil, "an empty OS is unknown, not excluded")
expect(GatewayCandidates.exclusion(peer("a.ts.net", user: 0), selfUserID: 7) == nil, "owner 0 is unknown, not another owner")
expect(GatewayCandidates.exclusion(peer("a.ts.net", user: 8), selfUserID: 0) == nil, "this node's owner 0 is unknown: no filter")
expect(GatewayCandidates.exclusion(peer("a.ts.net", os: "tvOS"), selfUserID: 7) != nil, "tvOS is not a server OS")
expect(GatewayCandidates.exclusion(GatewayPeer(host: "byskebox.ts.net", online: true, os: "linux", userID: 99, tagged: true),
                                   selfUserID: 7) == nil,
       "a TAGGED server passes the owner filter (it reports the tagged-devices user)")
expect(GatewayCandidates.exclusion(peer(""), selfUserID: 7) != nil, "no MagicDNS name is excluded")

print("== order")
let ps = [peer("zeta.ts.net."), peer("alpha.ts.net."), peer("phone.ts.net.", os: "iOS"),
          peer("byskebox.ts.net.", online: true), peer("ALPHA.ts.net")]
expect(hosts(GatewayCandidates.select(ps, selfUserID: 7, savedHost: nil)) == ["alpha.ts.net", "byskebox.ts.net", "zeta.ts.net"],
       "filtered, deduplicated case-insensitively, trailing dots dropped, alphabetical")
expect(hosts(GatewayCandidates.select(ps, selfUserID: 7, savedHost: "byskebox.ts.net"))
       == ["byskebox.ts.net", "alpha.ts.net", "zeta.ts.net"], "the saved gateway comes first")
expect(hosts(GatewayCandidates.select(ps, selfUserID: 7, savedHost: "PHONE.ts.net."))
       == ["phone.ts.net", "alpha.ts.net", "byskebox.ts.net", "zeta.ts.net"],
       "the saved gateway is probed even if the filters would skip it")
expect(GatewayCandidates.select(ps, selfUserID: 7, savedHost: "gone.ts.net").count == 3,
       "a saved gateway that is no longer a peer is simply absent")

print("== fingerprint")
let manifest = #"{"name": "Kiro Crew", "short_name": "Kiro Crew"}"#.data(using: .utf8)!
expect(GatewayCandidates.manifestIsKiroCrew(status: 200, body: manifest), "the real manifest matches")
expect(!GatewayCandidates.manifestIsKiroCrew(status: 404, body: manifest), "only a 200 counts")
expect(!GatewayCandidates.manifestIsKiroCrew(status: 200, body: #"{"name":"Kiro Crew Clone"}"#.data(using: .utf8)!), "an exact name")
expect(!GatewayCandidates.manifestIsKiroCrew(status: 200, body: Data("<!doctype html>".utf8)), "HTML is not a manifest")
expect(GatewayCandidates.authProbeIsKiroCrew(status: 403, authRequiredHeader: "true"), "403 + X-Auth-Required")
expect(!GatewayCandidates.authProbeIsKiroCrew(status: 403, authRequiredHeader: nil), "a bare 403 is not KiroCrew's")
expect(!GatewayCandidates.authProbeIsKiroCrew(status: 200, authRequiredHeader: nil), "an open /api/auth/me is not a KiroCrew denial")

print("== manual entry")
let sfx = "tail-scale.ts.net"
expect(GatewayCandidates.manualOrigin("dash", suffix: sfx) == "https://dash.tail-scale.ts.net", "a bare name is qualified")
expect(GatewayCandidates.manualOrigin("  Dash.Tail-Scale.ts.net.  ", suffix: sfx) == "https://dash.tail-scale.ts.net",
       "trimmed, lowercased, trailing dot dropped")
expect(GatewayCandidates.manualOrigin("http://dash.tail-scale.ts.net:5476/x?y", suffix: sfx) == "https://dash.tail-scale.ts.net",
       "always https, no port, path or query (R26)")
expect(GatewayCandidates.manualOrigin("https://gw.example.ts.net/", suffix: sfx) == "https://gw.example.ts.net",
       "another tailnet's FQDN is taken as typed")
expect(GatewayCandidates.manualOrigin("dash", suffix: nil) == "https://dash", "no suffix known: left bare")
expect(GatewayCandidates.manualOrigin("", suffix: sfx) == nil && GatewayCandidates.manualOrigin("a b", suffix: sfx) == nil,
       "nothing, or not a host")

print(failures == 0 ? "\(checks)/\(checks) gateway candidate checks passed" : "\(failures) of \(checks) gateway candidate checks FAILED")
exit(failures == 0 ? 0 : 1)
