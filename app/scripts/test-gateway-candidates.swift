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
expect(GatewayCandidates.exclusion(GatewayPeer(host: "gateway.ts.net", online: true, os: "linux", userID: 99, tagged: true),
                                   selfUserID: 7) == nil,
       "a TAGGED server passes the owner filter (it reports the tagged-devices user)")
expect(GatewayCandidates.exclusion(peer(""), selfUserID: 7) != nil, "no MagicDNS name is excluded")

print("== order")
let ps = [peer("zeta.ts.net."), peer("alpha.ts.net."), peer("phone.ts.net.", os: "iOS"),
          peer("gateway.ts.net.", online: true), peer("ALPHA.ts.net")]
expect(hosts(GatewayCandidates.select(ps, selfUserID: 7, savedHost: nil)) == ["alpha.ts.net", "gateway.ts.net", "zeta.ts.net"],
       "filtered, deduplicated case-insensitively, trailing dots dropped, alphabetical")
expect(hosts(GatewayCandidates.select(ps, selfUserID: 7, savedHost: "gateway.ts.net"))
       == ["gateway.ts.net", "alpha.ts.net", "zeta.ts.net"], "the saved gateway comes first")
expect(hosts(GatewayCandidates.select(ps, selfUserID: 7, savedHost: "PHONE.ts.net."))
       == ["phone.ts.net", "alpha.ts.net", "gateway.ts.net", "zeta.ts.net"],
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

print("== manual entry: the gate (M5.3, M5 review)")
// The live policy, as TSNetManager builds it: the MagicDNS suffix, each
// peer's FQDN and short name. `shared` is a node another tailnet shared in,
// so its FQDN is under a different suffix and only its own rule carries it.
let sfx = "tail-scale.ts.net"
let status = IpnState.Status(
    SelfStatus: IpnState.PeerStatus(HostName: "latchkey-iphone", DNSName: "latchkey-iphone.tail-scale.ts.net."),
    CurrentTailnet: IpnState.TailnetStatus(MagicDNSSuffix: sfx),
    Peer: ["d": IpnState.PeerStatus(HostName: "dash", DNSName: "dash.tail-scale.ts.net."),
           "s": IpnState.PeerStatus(HostName: "shared", DNSName: "shared.example.ts.net.")])
let policy = TailnetProxyPolicy.make(from: status)
typealias Refusal = GatewayCandidates.ManualEntryRefusal
extension Result where Failure == Refusal {
    var failureMessage: String? { if case .failure(let r) = self { return r.message }; return nil }
}
func gate(_ raw: String, suffix: String? = sfx, policy p: TailnetProxyPolicy? = policy) -> Result<String, Refusal> {
    GatewayCandidates.manualGateway(raw, suffix: suffix, policy: p)
}

expect(gate("dash") == .success("https://dash.tail-scale.ts.net"), "a bare name is qualified, and the suffix rule carries it")
expect(gate("  Dash.Tail-Scale.ts.net.  ") == .success("https://dash.tail-scale.ts.net"),
       "trimmed, lowercased, trailing dot dropped")
expect(gate("http://dash.tail-scale.ts.net:5476/x?y") == .success("https://dash.tail-scale.ts.net"),
       "always https, no port, path or query (R26)")
expect(gate("dash", suffix: nil) == .success("https://dash"), "no suffix known: left bare, carried by the short-name rule")
expect(gate("shared.example.ts.net") == .success("https://shared.example.ts.net"),
       "a node shared in from another tailnet is carried by its own FQDN rule")
expect(gate("") == .failure(.notAHost) && gate("a b") == .failure(.notAHost), "nothing, or not a host")

// The Settings hole: a public host typed there loaded direct, became the
// trusted origin, and would have received a pasted token.
expect(gate("evil.example") == .failure(.offTailnet(host: "evil.example")),
       "a public host is refused, whichever field it was typed into: \(gate("evil.example"))")
expect(gate("https://gw.example.ts.net/") == .failure(.offTailnet(host: "gw.example.ts.net")),
       "another tailnet's FQDN is refused unless this tailnet carries it (it used to be taken as typed)")
expect(gate("evil.example").failureMessage
       == "evil.example isn't on your tailnet. Enter the name of a computer on it, like gateway or gateway.<tailnet>.ts.net.",
       "the picker's wording, kept: \(gate("evil.example").failureMessage ?? "nil")")

// Fail closed. The picker's own check let a nil policy, or a host that did
// not re-parse, straight through.
expect(gate("dash", policy: nil) == .failure(.tailnetNotReady), "no policy: nothing is accepted")
expect(gate("dash", policy: .ipRangesOnly) == .failure(.tailnetNotReady),
       "the bootstrap policy (no peer data yet) accepts nothing, and says why rather than 'not on your tailnet'")
expect(gate("evil.example", policy: nil) == .failure(.tailnetNotReady), "no policy: not even a refusal that names a rule")
expect((gate("dash", policy: nil).failureMessage ?? "").contains("moment"), "the not-ready wording says to try again")

// Every acceptance is of the very host the origin names: no origin comes
// out whose host the policy does not carry.
for raw in ["dash", "DASH.tail-scale.ts.net", "https://shared.example.ts.net:8443/path", "latchkey-iphone",
            "gw_1", "dash..", "xn--80ak6aa92e", "evil.example", "shared", "not on tailnet"] {
    if case .success(let origin) = gate(raw) {
        let host = URLComponents(string: origin)?.host ?? ""
        expect(origin == "https://\(host)" && policy.matchingRule(for: host) != nil,
               "\(raw) -> \(origin): accepted only because the policy carries \(host)")
    }
}
expect(GatewayCandidates.isPlausibleGatewayName("dash", suffix: sfx)
       && GatewayCandidates.isPlausibleGatewayName("evil.example", suffix: sfx)
       && !GatewayCandidates.isPlausibleGatewayName("", suffix: sfx)
       && !GatewayCandidates.isPlausibleGatewayName("a b", suffix: sfx),
       "plausibility enables the button; it says nothing about the tailnet")

print(failures == 0 ? "\(checks)/\(checks) gateway candidate checks passed" : "\(failures) of \(checks) gateway candidate checks FAILED")
exit(failures == 0 ? 0 : 1)
