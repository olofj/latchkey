// Host tests for App/Session/DashboardSignOut.swift and
// App/Workspace/TailnetLogout.swift (R32).
import Foundation

var failures = 0
var checks = 0
func expect(_ cond: Bool, _ what: String) {
    checks += 1
    if !cond { failures += 1; print("  FAIL \(what)") }
}

print("== dashboard sign-out")
expect(DashboardSignOut.outcome(logoutStatus: 200) == .endedAtGateway, "200: the gateway ended the session")
expect(DashboardSignOut.outcome(logoutStatus: nil) == .endedLocally(gatewayStatus: nil),
       "no answer (unreachable, no page, timed out): local only")
expect(DashboardSignOut.outcome(logoutStatus: 403) == .endedLocally(gatewayStatus: 403),
       "a refusal (a CSRF 403, say) is local only, and the status is kept")
expect(DashboardSignOut.outcome(logoutStatus: 204) == .endedLocally(gatewayStatus: 204),
       "only 200 is the gateway's logged_out answer")
expect(DashboardSignOut.notice(for: .endedAtGateway) == nil, "nothing to add when the gateway confirmed")
let unreachable = DashboardSignOut.notice(for: .endedLocally(gatewayStatus: nil)) ?? ""
let refused = DashboardSignOut.notice(for: .endedLocally(gatewayStatus: 403)) ?? ""
expect(unreachable.contains("this device only") && unreachable.contains("reached"),
       "unreachable: says the sign-out was local and why: \(unreachable)")
expect(refused.contains("this device only") && refused.contains("403"),
       "refused: says the sign-out was local and what the gateway said: \(refused)")
expect(unreachable.contains("30 days") && refused.contains("30 days"),
       "both say how long the gateway keeps the session")
expect(DashboardSignOut.requestTimeout >= .seconds(5) && DashboardSignOut.requestTimeout <= .seconds(30),
       "the page-world logout is bounded, and not so short a slow relay fails it")

print("== tailnet logout request")
let r = TailnetLogout.request(ip: "127.0.0.1", port: 41234, localAPIKey: "k3y+/=")
expect(r?.url?.absoluteString == "http://127.0.0.1:41234/localapi/v0/logout", "LocalAPI's logout endpoint: \(r?.url?.absoluteString ?? "nil")")
expect(r?.httpMethod == "POST", "serveLogout wants POST")
// TailscaleKit: base64("tsnet:<localAPIKey>"), which the loopback checks.
let wantAuth = "Basic " + Data("tsnet:k3y+/=".utf8).base64EncodedString()
expect(r?.value(forHTTPHeaderField: "Authorization") == wantAuth,
       "Basic auth as TailscaleKit sends it: \(r?.value(forHTTPHeaderField: "Authorization") ?? "nil")")
expect(r?.value(forHTTPHeaderField: "Sec-Tailscale") == "localapi", "the header the loopback insists on")
expect(r?.timeoutInterval == TailnetLogout.timeout && TailnetLogout.timeout >= 10 && TailnetLogout.timeout <= 60,
       "bounded: a reset must not wait on control forever (\(TailnetLogout.timeout)s)")
expect(TailnetLogout.request(ip: "127.0.0.1", port: 1, localAPIKey: "k", timeout: 3)?.timeoutInterval == 3, "the timeout is the caller's")
expect(TailnetLogout.succeeded(status: 204) && TailnetLogout.succeeded(status: 200), "204 (serveLogout) is success")
expect(!TailnetLogout.succeeded(status: 500) && !TailnetLogout.succeeded(status: 403) && !TailnetLogout.succeeded(status: 0),
       "a Logout error (500), a read-only handler (403) or no answer is not")

print("== tailnet logout outcome (R32 review)")
// serveLogout answers 204 for a node with no key too: what the node had
// before the call decides what a 2xx meant, and the log must not claim an
// expiry that never happened.
expect(TailnetLogout.outcome(status: 204, hadKey: true) == .loggedOut, "204 with a key: expired at control")
expect(TailnetLogout.outcome(status: 200, hadKey: true) == .loggedOut, "any 2xx with a key: expired at control")
expect(TailnetLogout.outcome(status: 204, hadKey: false) == .noKey, "204 without a key: nothing was expired")
expect(TailnetLogout.outcome(status: 500, hadKey: true) == .failed("LocalAPI answered 500"),
       "a Logout error keeps the key at control, and the status is kept")
expect(TailnetLogout.outcome(status: 0, hadKey: false) == .failed("LocalAPI answered 0"),
       "no answer is a failure even without a key: the state must not be deleted on a guess")
// The alert when the logout failed: the choice is the user's, the cost of
// "Delete anyway" is spelled out, and the node is never called "left".
let message = TailnetLogout.failureMessage("timed out")
expect(TailnetLogout.failureTitle.contains("Couldn't reach Tailscale"), "the title says what could not be done")
expect(message.contains("timed out"), "the reason is in the message: \(message)")
expect(message.contains("admin console") && message.contains("valid key") && message.contains("removes it there"),
       "Delete anyway's cost: the node stays in the admin console with a valid key until removed there: \(message)")
expect(message.contains("Cancel keeps the node"), "and Cancel is explained: \(message)")

print(failures == 0 ? "\(checks)/\(checks) sign-out checks passed" : "\(failures) of \(checks) sign-out checks FAILED")
exit(failures == 0 ? 0 : 1)
