// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

//
//  LifecycleHarnessTests.swift
//  LatchkeyUITests
//
//  L2 lifecycle hardening (PLAN M6.5, M6.7): the real tsnet node on the fake
//  tailnet, with its sockets damaged mid-session and its process frozen.
//
//  The inherited versions of these tests (LatchkeyUITests) need a real
//  tailnet and an auth key. These run on testing/tsnet-harness with no
//  account, and read their evidence server-side, as the other L2 suites do
//  (R13): the fake dashboard stamps every report with the time it received
//  it, the page counts its own reconnects, and the dash peer journals every
//  tailnet connection with its source address and time. So "the page came
//  back" is a report received after the damage, from the same document, and
//  "over the tailnet" is a journal entry from the app node after it.
//
//  Two kinds of damage:
//  - TCP chaos (M6.7, R14): the app's own test hooks shut down the sockets
//    the way iOS defuncts them. Recovery is failure-driven (`TSNetManager.
//    recoverLoopbackAfterFailure`), so no lifecycle event is needed.
//  - A frozen process (M6.5): Home, then the host stops the process with
//    SIGSTOP for a chosen time and continues it (scripts/test-lifecycle.sh,
//    after app/scripts/test-lock-resume.sh). Swift, URLSession, Network.
//    framework and the Go runtime all stop together, which is what a
//    suspended app looks like to the rest of the world. The simulator never
//    suspends by itself (M6.6 is the device pass).
//
//  Needs both harnesses, the test CA and the host freezer:
//  `scripts/test-lifecycle.sh` (parent repo).
//

import XCTest

@MainActor
final class LifecycleHarnessTests: XCTestCase {

    static let controlURL = "http://127.0.0.1:8490"
    static let harnessAPI = "http://127.0.0.1:8491"
    static let dashboardControl = "http://127.0.0.1:8480"
    static let gateway = "https://dash.tail-scale.ts.net"
    static let gatewayHost = "dash.tail-scale.ts.net"

    /// A cold node's first join against the loopback control plane, plus the
    /// page's WebSocket. Measured at 5–8 s; 60 s is the same allowance the
    /// other L2 suites give it.
    static let joinTimeout: TimeInterval = 60

    /// M6's AC: after a background, an interactive dashboard within 5 s on a
    /// real device. The inherited simulator test allowed 7 s for the UI; the
    /// same here, and the same for the first request that crosses the tailnet
    /// afterwards.
    static let resumeBudget: TimeInterval = 7

    /// Where the host freezer (scripts/test-lifecycle.sh) and these tests
    /// meet: the test writes a request, the freezer writes the result.
    nonisolated static let freezerDir = "/tmp/latchkey-lifecycle"

    override func setUp() async throws {
        continueAfterFailure = false
        guard (try? await Self.get("\(Self.harnessAPI)/healthz")) != nil,
              (try? await Self.get("\(Self.dashboardControl)/__state")) != nil
        else {
            XCTFail("The L2 harness is not running. Use scripts/test-lifecycle.sh (parent repo).")
            return
        }
        _ = try await Self.post("\(Self.dashboardControl)/__reset")
    }

    // MARK: - M6.7: TCP chaos, both hooks

    /// Every TCP socket in the process is shut down (`-UITestShutdownTCPConnections`):
    /// the LocalAPI stream and the relay's sessions among them. This is iOS
    /// defuncting a suspended process's sockets. What must hold is that the
    /// app SURVIVES it (this is the test that caught a nil-`Logf` panic in the
    /// vendored hook, M6) and the page comes back by itself.
    ///
    /// Measured on the simulator: `shutdown(SHUT_RDWR)` cuts ESTABLISHED
    /// connections but returns ENOTCONN on LISTENING sockets, so tsnet's
    /// loopback listener stays up, LocalAPI's next request succeeds on a fresh
    /// connection, and loopback recovery never fires -- correctly, the
    /// loopback is fine. WebKit's own sockets live in its network process, not
    /// this one, but the relay's do, so the page's WebSocket relay session
    /// dies and the page reconnects through the surviving listener. (A device
    /// defuncts listeners too; that is M6.6.)
    func testShutDownTCPSocketsAreSurvivedAndThePageReconnects() async throws {
        try await runTCPChaos(hook: "-UITestShutdownTCPConnections", expectsLoopbackRecovery: false)
    }

    /// Only the tsnet loopback listener is closed (`-UITestDefunctLoopback`),
    /// while every accepted connection lives on: a retained endpoint that
    /// refuses new connections. The app's next LocalAPI poll fails and the
    /// listener is replaced (status "recovered"). The page's open WebSocket
    /// survives the damage and must go on carrying frames through the old
    /// relay; then what must be shown is that a NEW connection gets through
    /// the replacement -- a gateway-restart drop, then reconnect.
    func testDefunctLoopbackListenerIsReplacedAndNewConnectionsGetThrough() async throws {
        try await runTCPChaos(hook: "-UITestDefunctLoopback", expectsLoopbackRecovery: true)
    }

    /// Both hooks, up to the cut: the dashboard is up over the tailnet, the
    /// hook fires, and after the cut the page reconnects through whatever
    /// WebKit has then, the dash peer journals it, and no error page shows.
    /// What the cut IS differs: for the closed listener the app replaces it
    /// ("recovered") and the page's still-open socket has to be dropped like a
    /// gateway restart to force a new connection; for the shut-down sockets
    /// the damage itself cut the page's socket and no listener replacement is
    /// expected -- only survival and the page's own reconnect.
    private func runTCPChaos(hook: String, expectsLoopbackRecovery: Bool,
                             file: StaticString = #filePath, line: UInt = #line) async throws {
        try await resetHarness()
        let launchedAt = Date()
        let app = launch(extra: [hook, "-UITestTCPChaosDelay", Self.chaosDelay])
        defer { app.terminate() }

        // 1. The dashboard is up over the tailnet, before anything is damaged.
        //    (The hook fires `chaosDelay` after the app's first `Running`
        //    status poll, which is also the poll that lets the first load
        //    start.)
        let up = try await waitForReport(timeout: Self.joinTimeout) { $0["ws"] as? String == "ws:open" }
        let joinSeconds = Date().timeIntervalSince(launchedAt)
        let doc = up["doc"] as? String ?? ""
        let upAt = up["received_at"] as? Double ?? 0
        let node = try await appNode()
        let before = try await journal(from: node)
        XCTAssertFalse(before.isEmpty, "the first load crossed the tailnet; journal empty", file: file, line: line)

        // 2. The damage.
        let chaos = app.staticTexts["tcp-chaos-test-status"]
        let damagedAt = try await waitForChaosStatus(app, chaos, oneOf: ["damaged", "recovered"], timeout: 30)
        XCTAssertLessThan(upAt, damagedAt.timeIntervalSince1970,
                          "the page was up before the damage, or this tests a first load, not a recovery",
                          file: file, line: line)

        // 3. The cut the page's reconnect has to cross.
        let cutAt: Date
        var recoverySeconds = 0.0
        if expectsLoopbackRecovery {
            // The listener was CLOSED: the app notices from a LocalAPI failure
            // (the IPN stream or the 5-s poll) and replaces it. The page's
            // accepted socket survived, so drop it as a gateway restart does;
            // the reconnect then has to reach the REPLACEMENT listener.
            let recoveredAt = try await waitForChaosStatus(app, chaos, oneOf: ["recovered"], timeout: 45)
            recoverySeconds = recoveredAt.timeIntervalSince(damagedAt)
            let survived = try await latestReport()
            XCTAssertEqual(survived["ws"] as? String, "ws:open",
                           "a closed listener does not cut the accepted connections: \(survived)",
                           file: file, line: line)
            // And the surviving socket still carries traffic, frame after
            // frame. The replaced relay once relayed ONE more chunk per
            // session and then hung with the socket open (M6 review): the
            // first push would pass, the second never arrive.
            for text in ["survivor-1", "survivor-2"] {
                let pushReply = try await Self.post("\(Self.dashboardControl)/__ws_push?text=\(text)")
                let pushed = (try JSONSerialization.jsonObject(with: pushReply) as? [String: Any])?["pushed"] as? Int ?? 0
                XCTAssertGreaterThanOrEqual(pushed, 1, "the dashboard pushed \(text) down the page's socket",
                                            file: file, line: line)
                _ = try await waitForReport(timeout: 10) { r in
                    r["doc"] as? String == doc && r["echo"] as? String == "echo:\(text)"
                }
            }
            let reply = try await Self.post("\(Self.dashboardControl)/__drop_ws")
            let dropped = (try JSONSerialization.jsonObject(with: reply) as? [String: Any])?["dropped"] as? Int ?? 0
            XCTAssertGreaterThanOrEqual(dropped, 1, "the dashboard dropped the page's WebSocket", file: file, line: line)
            cutAt = Date()
        } else {
            // shutdown() cut every established connection in THIS process --
            // the relay's sessions with them -- but left the listeners, so no
            // loopback recovery is due; the damage itself was the cut, and the
            // app must simply survive it and the page reconnect.
            cutAt = damagedAt
        }

        // 4. The page reconnects by itself: the same document (no app-side
        //    reload), at least one reconnect, the socket open, the reconnect's
        //    HTTP refetch, and a report received after the cut -- so it went
        //    through the listener that is live now.
        let back = try await waitForReport(timeout: 60) { r in
            r["doc"] as? String == doc && r["ws"] as? String == "ws:open"
                && (r["reconnects"] as? Int ?? 0) >= 1
                && (r["refetches"] as? Int ?? 0) >= 1
                && (r["received_at"] as? Double ?? 0) > cutAt.timeIntervalSince1970
        }
        let reconnectSeconds = (back["received_at"] as? Double ?? 0) - cutAt.timeIntervalSince1970
        XCTAssertEqual(back["next_delay_ms"] as? Int, 1000,
                       "the backoff resets to 1 s once the socket opens: \(back)", file: file, line: line)

        // 5. Over the tailnet: a connection from the app node after the cut.
        let after = try await journal(from: node).filter { $0.at > cutAt.timeIntervalSince1970 }
        XCTAssertFalse(after.isEmpty,
                       "the dash peer journals a NEW connection from the app node after the cut",
                       file: file, line: line)

        // 6. The app is alive and no error page: recovery was silent.
        XCTAssertEqual(app.state, .runningForeground,
                       "the app survived having its sockets cut", file: file, line: line)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "nav-error-overlay").firstMatch.exists,
                       "no navigation error is shown", file: file, line: line)

        if expectsLoopbackRecovery {
            print("LIFECYCLE \(hook): " + String(
                format: "join %.1f s; damage -> recovered %.1f s; drop -> page back %.1f s",
                joinSeconds, recoverySeconds, reconnectSeconds))
        } else {
            print("LIFECYCLE \(hook): " + String(
                format: "join %.1f s; damage -> page reconnected %.1f s (no loopback recovery expected)",
                joinSeconds, reconnectSeconds))
        }
    }

    // MARK: - R30: the relay's own listener, restarted by a failed page load

    /// Only the app's SOCKS relay listener dies (`-UITestDefunctRelayListener`),
    /// with every session it carried; tsnet's listener stays up, so the
    /// status poll sees nothing and loopback recovery never runs. The page's
    /// own reconnect cannot help either: its attempts are subresource
    /// requests to the dead port, and only a main-frame load that fails on
    /// transport reaches `TSNetManager.pageLoadFailed`. So the test does
    /// what a user does -- follows a link on the page -- and that failed
    /// load must restart the listener, republish the proxy configuration,
    /// and retry the page by itself, with the error page gone.
    func testDefunctRelayListenerIsRestartedByAFailedPageLoad() async throws {
        try await resetHarness()
        let app = launch(extra: ["-UITestDefunctRelayListener", "-UITestTCPChaosDelay", Self.chaosDelay])
        defer { app.terminate() }
        let up = try await waitForReport(timeout: Self.joinTimeout) { $0["ws"] as? String == "ws:open" }
        let doc = up["doc"] as? String ?? ""
        let upAt = up["received_at"] as? Double ?? 0
        let node = try await appNode()

        let chaos = app.staticTexts["tcp-chaos-test-status"]
        let damagedAt = try await waitForChaosStatus(app, chaos,oneOf: ["relay damaged", "relay recovered"], timeout: 30)
        XCTAssertLessThan(upAt, damagedAt.timeIntervalSince1970,
                          "the page was up before the damage, or this tests a first load, not a recovery")

        // The page's socket went with the relay's sessions, and its reconnect
        // attempts go to the dead port: none arrives. Nothing the app polls
        // notices either -- after a full status poll it still reads damaged.
        _ = try await waitForDashboard(timeout: 15) { ($0["ws_open"] as? Int) == 0 }
        try await Task.sleep(for: .seconds(6))
        let stillDamaged = chaos.label
        XCTAssertEqual(stillDamaged, "relay damaged",
                       "a dead relay listener is invisible to the status poll; only a failed page load can notice")
        let stillClosed = try await dashboardState()["ws_open"] as? Int
        XCTAssertEqual(stillClosed, 0, "the page's own reconnect attempts cannot reach the dead listener")

        // A main-frame navigation, as a user makes one: the page's own link.
        let link = app.webViews.links["Open again"]
        XCTAssertTrue(link.waitForExistence(timeout: 10), "the page's link renders")
        link.tap()
        let tappedAt = Date()
        let recoveredAt = try await waitForChaosStatus(app, chaos,oneOf: ["relay recovered"], timeout: 30)
        let noticeSeconds = recoveredAt.timeIntervalSince(tappedAt)

        // The app retries the failed navigation on the republished endpoint:
        // a NEW document, carrying the link's query, its socket open, received
        // after the recovery -- through the replacement listener.
        let back = try await waitForReport(timeout: 30) { r in
            r["doc"] as? String != doc && r["search"] as? String == "?again" && r["ws"] as? String == "ws:open"
                && (r["received_at"] as? Double ?? 0) > recoveredAt.timeIntervalSince1970
        }
        let retrySeconds = (back["received_at"] as? Double ?? 0) - recoveredAt.timeIntervalSince1970
        let after = try await journal(from: node).filter { $0.at > tappedAt.timeIntervalSince1970 }
        XCTAssertFalse(after.isEmpty, "the retried load crossed the tailnet")
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "nav-error-overlay").firstMatch.exists,
                       "the retry took the error page down")

        // Status counts it, so a device log-less debugging session can see it.
        let list = app.openStatus()
        let restarts = app.statusRow("diag-relay-restarts", in: list)
        XCTAssertTrue(restarts.hasSuffix("1"), "Status counts one relay restart: \(restarts)")
        app.buttons["diagnostics-done-button"].tap()
        app.buttons["settings-done-button"].firstMatch.tap()

        print("LIFECYCLE -UITestDefunctRelayListener: " + String(
            format: "link tap -> relay recovered %.1f s; recovered -> page back %.1f s", noticeSeconds, retrySeconds))
    }

    // MARK: - M6.5: a frozen process (SIGSTOP), then resume

    /// Seven seconds: the inherited script's default -- past the scene
    /// transition and one 5-s status poll, the shape of a lock/unlock.
    func testResumeAfterASevenSecondFreezeKeepsThePageAndReachesTheTailnet() async throws {
        try await runFreeze(seconds: 7)
    }

    /// Thirty seconds: every periodic thing in the path has fired or expired
    /// at least once while the process was frozen -- the 5-s status poll (six
    /// of them), the page's 1-s reports and 10-s backoff cap, and more than
    /// the SSE server's 0.5-s ticks can buffer harmlessly. Long enough that a
    /// timer-driven fault shows, short enough for a UI test. Ten minutes and
    /// overnight are device-only (M6.6): the simulator never really suspends.
    func testResumeAfterAThirtySecondFreezeKeepsThePageAndReachesTheTailnet() async throws {
        try await runFreeze(seconds: 30)
    }

    private func runFreeze(seconds: Int, file: StaticString = #filePath, line: UInt = #line) async throws {
        try await resetHarness()
        let launchedAt = Date()
        let app = launch()
        defer { app.terminate() }
        let up = try await waitForReport(timeout: Self.joinTimeout) { $0["ws"] as? String == "ws:open" }
        let joinSeconds = Date().timeIntervalSince(launchedAt)
        let doc = up["doc"] as? String ?? ""
        let node = try await appNode()

        // Ask the host freezer for `seconds`, then go to the background. The
        // freezer acts on the app's own "Background:" log line, so the
        // scene transition has happened before the process stops.
        let request = try Freezer.request(seconds: seconds)
        XCUIDevice.shared.press(.home)

        // While frozen, nothing can reach the dashboard: every request goes
        // through the app's relay and node. The samples prove the freeze bit.
        var samples: [Double] = []
        let result = try await Freezer.waitForResult(of: request, timeout: TimeInterval(seconds) + 90) {
            if let r = try? await self.latestReport(), let t = r["received_at"] as? Double { samples.append(t) }
        }
        XCTAssertGreaterThanOrEqual(result.continuedAt - result.stoppedAt, Double(seconds) - 0.5,
                                    "the freezer held the process for \(seconds) s: \(result)", file: file, line: line)
        let during = Set(samples).filter { $0 > result.stoppedAt + 0.5 && $0 < result.continuedAt }
        XCTAssertTrue(during.isEmpty,
                      "no report reached the dashboard while the app was frozen (it is the only way there): \(during)",
                      file: file, line: line)

        // Resume.
        app.activate()
        let activatedAt = Date()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "connected-browser").firstMatch
                        .waitForExistence(timeout: Self.resumeBudget),
                      "the dashboard is there on resume", file: file, line: line)
        XCTAssertTrue(app.webViews.firstMatch.exists, "the web view was retained", file: file, line: line)

        // A fresh request after activation crosses the tailnet: the page's
        // visibilitychange refetch (a request the page could only make after
        // becoming visible), reported from the SAME document -- the tab kept
        // its page -- and received after activation, by the server's clock.
        let visibleBefore = up["visible_fetches"] as? Int ?? 0
        let fresh = try await waitForReport(timeout: Self.resumeBudget) { r in
            r["doc"] as? String == doc
                && (r["visible_fetches"] as? Int ?? 0) > visibleBefore
                && (r["received_at"] as? Double ?? 0) > activatedAt.timeIntervalSince1970
        }
        let freshSeconds = (fresh["received_at"] as? Double ?? 0) - activatedAt.timeIntervalSince1970
        XCTAssertEqual(fresh["ws"] as? String, "ws:open",
                       "the WebSocket is open after the resume (kept, or reconnected): \(fresh)", file: file, line: line)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "nav-error-overlay").firstMatch.exists,
                       "no navigation error is shown", file: file, line: line)

        // And over the tailnet: the app node is still the one connecting.
        let entries = try await journal(from: node)
        XCTAssertFalse(entries.isEmpty, "the load crossed the tailnet", file: file, line: line)
        print("LIFECYCLE freeze \(seconds) s: " + String(
            format: "join %.1f s; frozen %.1f s; resume -> fresh request %.2f s; reconnects %d",
            joinSeconds, result.continuedAt - result.stoppedAt, freshSeconds, fresh["reconnects"] as? Int ?? 0))
    }

    // MARK: - The host freezer's protocol (scripts/test-lifecycle.sh)

    /// The test writes `request.json` ({id, seconds}) and goes to the
    /// background; the freezer, on the app's "Background:" log line, stops
    /// the process for `seconds`, continues it, and writes `result.json`
    /// ({id, pid, seconds, stopped_at, continued_at}). Without the freezer
    /// the wait times out and the test fails: a Home/activate without a
    /// frozen process would be a weaker test passing for this one.
    private enum Freezer {
        struct Request { let id: String; let seconds: Int }
        struct Result: CustomStringConvertible {
            let pid: Int
            let stoppedAt: Double
            let continuedAt: Double
            var description: String {
                String(format: "pid %d stopped at %.3f, continued at %.3f (%.1f s)",
                       pid, stoppedAt, continuedAt, continuedAt - stoppedAt)
            }
        }

        static var requestPath: String { "\(LifecycleHarnessTests.freezerDir)/request.json" }
        static var resultPath: String { "\(LifecycleHarnessTests.freezerDir)/result.json" }

        static func request(seconds: Int) throws -> Request {
            let fm = FileManager.default
            try fm.createDirectory(atPath: LifecycleHarnessTests.freezerDir, withIntermediateDirectories: true)
            try? fm.removeItem(atPath: resultPath)
            let id = UUID().uuidString
            let data = try JSONSerialization.data(withJSONObject: ["id": id, "seconds": seconds])
            try data.write(to: URL(fileURLWithPath: requestPath), options: .atomic)
            return Request(id: id, seconds: seconds)
        }

        /// Polls for the result every 250 ms, calling `tick` between polls.
        /// On the main actor, as the tests are: `tick` reads the dashboard.
        @MainActor
        static func waitForResult(of request: Request, timeout: TimeInterval,
                                  tick: () async -> Void) async throws -> Result {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if let data = FileManager.default.contents(atPath: resultPath),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   obj["id"] as? String == request.id,
                   let pid = obj["pid"] as? Int,
                   let stopped = obj["stopped_at"] as? Double,
                   let continued = obj["continued_at"] as? Double {
                    return Result(pid: pid, stoppedAt: stopped, continuedAt: continued)
                }
                await tick()
                try await Task.sleep(for: .milliseconds(250))
            }
            throw HarnessError("the host freezer never reported a freeze of \(request.seconds) s "
                               + "(no \(resultPath) for \(request.id)); run this suite through scripts/test-lifecycle.sh")
        }
    }

    // MARK: - Launch

    private func launch(extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-UITestResetWorkspaces",
            "-UITestHomePage", Self.gateway,
            "-TestControlURL", Self.controlURL,
        ] + extra
        app.launch()
        return app
    }

    /// The chaos hooks fire this long after the app's first `Running` status
    /// poll -- the poll that also starts the first load. Upstream's 2 s lost
    /// the race to a cold WebKit's first load (measured: the page came up
    /// about 2 s after the poll, and the damage then landed on the load
    /// itself). Eight leaves room; the tests check the order anyway.
    static let chaosDelay = "8"

    /// The chaos hook's status label, polled (an XCUIElement inside a
    /// predicate block is the thing to avoid). Returns when it reads one of
    /// `oneOf`; fails the test otherwise, showing what it read -- and says
    /// so when the app itself is gone, which is a crash to go and read.
    private func waitForChaosStatus(_ app: XCUIApplication, _ element: XCUIElement, oneOf wanted: Set<String>,
                                    timeout: TimeInterval) async throws -> Date {
        let deadline = Date().addingTimeInterval(timeout)
        var last = "<absent>"
        while Date() < deadline {
            if app.state != .runningForeground {
                throw HarnessError("the app is no longer running (state \(app.state.rawValue)) while waiting for "
                                   + "tcp-chaos-test-status \(wanted.sorted()); a crash? see ~/Library/Logs/DiagnosticReports "
                                   + "and the container's Logs/stderr.log; last: \(last)")
            }
            if element.exists {
                last = element.label
                if wanted.contains(last) { return Date() }
                if last.hasPrefix("failed") { break }
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw HarnessError("tcp-chaos-test-status never read \(wanted.sorted()) within \(Int(timeout)) s; last: \(last)")
    }

    // MARK: - Harness (testing/tsnet-harness)

    private func resetHarness() async throws {
        let data = try await Self.post("\(Self.harnessAPI)/reset?auth=0&machine=0", timeout: 90)
        let state = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        XCTAssertNotNil(state["generation"], "reset failed: \(String(decoding: data, as: UTF8.self))")
    }

    private func harnessState() async throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: try await Self.get("\(Self.harnessAPI)/state")) as? [String: Any] ?? [:]
    }

    private struct Node {
        let hostname: String
        let addresses: [String]
    }

    /// The one node that is not the harness's own: the app's.
    private func appNode() async throws -> Node {
        var last: [[String: Any]] = []
        for _ in 0..<60 {
            last = try await harnessState()["nodes"] as? [[String: Any]] ?? []
            let apps = last.filter { $0["harnessPeer"] as? Bool == false }
            if apps.count > 1 { XCTFail("expected one app node, found \(apps.count): \(apps)") }
            if let n = apps.first {
                return Node(hostname: n["hostname"] as? String ?? "", addresses: n["addresses"] as? [String] ?? [])
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw HarnessError("the app's node never registered with the harness; nodes: \(last)")
    }

    private struct Entry { let at: Double }

    /// The dash peer's journal entries from the app node's tailnet address:
    /// each is one connection that crossed the tailnet, with when it arrived.
    private func journal(from node: Node) async throws -> [Entry] {
        let journal = try await harnessState()["journal"] as? [[String: Any]] ?? []
        return journal.compactMap { e in
            guard e["peer"] as? String == "dash", e["error"] == nil,
                  node.addresses.contains(where: { addr in
                      let from = e["from"] as? String ?? ""
                      return from.hasPrefix("\(addr):") || from.hasPrefix("[\(addr)]:")
                  }),
                  let at = Self.parseTime(e["at"] as? String)
            else { return nil }
            return Entry(at: at)
        }
    }

    /// Go's RFC 3339 (`2026-09-21T14:25:30.930123-07:00`, up to nine
    /// fractional digits, trailing zeros dropped) to epoch seconds. The
    /// fraction is parsed apart: ISO8601DateFormatter wants exactly three.
    private static func parseTime(_ s: String?) -> Double? {
        guard let s, let m = s.wholeMatch(of: /(.*T\d\d:\d\d:\d\d)(\.\d+)?(Z|[+-]\d\d:\d\d)/) else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        guard let base = f.date(from: String(m.1) + String(m.3)) else { return nil }
        let fraction = m.2.flatMap { Double("0" + $0) } ?? 0
        return base.timeIntervalSince1970 + fraction
    }

    private struct HarnessError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    // MARK: - Dashboard (testing/harness/dashboard.py)

    private func dashboardState() async throws -> [String: Any] {
        try JSONSerialization.jsonObject(
            with: try await Self.get("\(Self.dashboardControl)/__state")) as? [String: Any] ?? [:]
    }

    private func latestReport() async throws -> [String: Any] {
        (try await dashboardState()["reports"] as? [String: [String: Any]])?[Self.gatewayHost] ?? [:]
    }

    @discardableResult
    private func waitForDashboard(timeout: TimeInterval,
                                  until predicate: ([String: Any]) -> Bool) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        var last: [String: Any] = [:]
        while Date() < deadline {
            last = try await dashboardState()
            if predicate(last) { return last }
            try await Task.sleep(for: .milliseconds(250))
        }
        XCTFail("the dashboard's state never matched within \(Int(timeout))s; ws_open: \(last["ws_open"] ?? "?")")
        return last
    }

    private func waitForReport(timeout: TimeInterval,
                               until predicate: ([String: Any]) -> Bool) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        var last: [String: Any] = [:]
        while Date() < deadline {
            let r = try await latestReport()
            if !r.isEmpty {
                last = r
                if predicate(r) { return r }
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        XCTFail("no matching report from \(Self.gatewayHost) within \(Int(timeout))s; last: \(last)")
        return last
    }

    private static func get(_ url: String) async throws -> Data {
        var request = URLRequest(url: URL(string: url)!, timeoutInterval: 5)
        request.httpMethod = "GET"
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    @discardableResult
    private static func post(_ url: String, timeout: TimeInterval = 5) async throws -> Data {
        var request = URLRequest(url: URL(string: url)!, timeoutInterval: timeout)
        request.httpMethod = "POST"
        let (data, _) = try await URLSession.shared.data(for: request)
        return data
    }
}
