// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

//
//  DiscoveryTests.swift
//  LatchkeyUITests
//
//  M5: gateway discovery (revision R26), on the L2 harness.
//
//  The app's real node joins testing/tsnet-harness, started with extra
//  peers, so the tailnet holds exactly the cases discovery must tell apart:
//    gw     forwards to the fake KiroCrew gateway (the real 0.6.0 manifest,
//           and a 403 + X-Auth-Required /api/auth/me): a gateway
//    dash   forwards to dashboard.py, a web page but not KiroCrew
//    plain  nothing listening
//    slow   accepts and never answers: must not stall the sweep
//  All four are online, owned by the same user and report macOS, so all pass
//  R26's filters; the fingerprint alone decides.
//
//  The device-check rehearsal (DEVICE-CHECK.md §3-4) adds the harness's
//  purgatory: every peer drops the app node's traffic until the harness
//  moves its address into the fixture clients range, while it runs.
//
//  No -UITestHomePage: the app starts with no gateway, as a first run does.
//  Needs scripts/test-discovery.sh (parent repo).
//

import XCTest

@MainActor
final class DiscoveryTests: XCTestCase {

    static let controlURL = "http://127.0.0.1:8490"
    static let harnessAPI = "http://127.0.0.1:8491"
    static let gatewayControl = "http://127.0.0.1:8481"
    static let dashboardControl = "http://127.0.0.1:8480"
    static let gatewayHost = "gw.tail-scale.ts.net"

    override func setUp() async throws {
        continueAfterFailure = false
        guard (try? await Self.get("\(Self.harnessAPI)/healthz")) != nil,
              (try? await Self.get("\(Self.gatewayControl)/__state")) != nil
        else {
            XCTFail("The discovery harness is not running. Use scripts/test-discovery.sh (parent repo).")
            return
        }
        try await resetFakes()
    }

    /// Both fakes forget everything, and are checked to have (M5 review: a
    /// silently failed reset would let an earlier test's probe satisfy a
    /// later test's "was probed" check).
    private func resetFakes() async throws {
        _ = try await Self.post("\(Self.gatewayControl)/__reset")
        _ = try await Self.post("\(Self.dashboardControl)/__reset")
        let paths = try await dashboardState()["paths"] as? [String] ?? ["<unreadable>"]
        let requests = try await gatewayState()["requests"] as? [String] ?? ["<unreadable>"]
        XCTAssertTrue(paths.isEmpty && requests.isEmpty, "the fakes did not reset: \(paths.prefix(3)) \(requests.prefix(3))")
    }

    /// First run: discovery finds exactly the gateway, within R26's budget,
    /// chooses it (the only one), and the dashboard loads it over the tailnet
    /// — reaching the session layer, which asks for a token.
    func testFirstRunFindsExactlyTheGatewayAndLoadsIt() async throws {
        try await resetHarness()
        let app = launch()
        defer { app.terminate() }

        // The picker is up only for the sweep (~1.5 s), too briefly to catch
        // reliably. What proves the result is what follows it: the app
        // chooses a gateway by itself ONLY when exactly one was found. The
        // sweep's timing is R26's app-logged instrument, which
        // scripts/test-discovery.sh enforces from the unified log.
        // Chosen automatically, loaded, and the page asks for a token.
        let sheet = element(app, "token-sheet")
        XCTAssertTrue(sheet.waitForExistence(timeout: 75),
                      "exactly one gateway found, chosen by itself, loaded, and asking for a token")
        XCTAssertTrue(element(app, "token-sheet-target").label.hasSuffix(Self.gatewayHost))

        // The probes really went out: the gateway answered both fingerprint
        // requests, and the non-gateway page was asked too.
        // The probe, in order, before anything else: the manifest, then the
        // unauthenticated /api/auth/me (the page's own calls come after).
        let requests = try await gatewayState()["requests"] as? [String] ?? []
        XCTAssertEqual(Array(requests.prefix(2)), ["GET /manifest.json", "GET /api/auth/me"],
                       "the fingerprint probe came first: \(requests.prefix(6))")
        let dashPaths = try await dashboardState()["paths"] as? [String] ?? []
        XCTAssertTrue(dashPaths.contains { $0.hasPrefix("dash.tail-scale.ts.net GET /manifest.json") },
                      "dash was probed and rejected: \(dashPaths.prefix(5))")
        // The peer that never answers was probed too (its accepts are
        // journaled); plain's refusal shows only in the app's own sweep log,
        // which scripts/test-discovery.sh checks.
        let journal = try await harnessState()["journal"] as? [[String: Any]] ?? []
        XCTAssertTrue(journal.contains { $0["peer"] as? String == "slow" },
                      "the slow peer was probed: \(journal.prefix(5))")
    }

    /// Nothing found: the picker says so, and manual entry works — a bare
    /// name is qualified with the tailnet's suffix and loaded.
    func testManualEntryWhenNoGatewayIsFound() async throws {
        try await resetHarness(withGateway: false)
        let app = launch()
        defer { app.terminate() }

        XCTAssertTrue(element(app, "gateway-picker").waitForExistence(timeout: 60))
        XCTAssertTrue(element(app, "gateway-none").waitForExistence(timeout: 15), "no gateway found, and it says so")
        // The marker gained answered/unanswered fields (F4 §4.8). Read by field
        // rather than by whole-string equality, which is what it was: F4 claimed
        // "existing tests read only the first field and keep working" and this
        // assertion disproved it.
        let done = try sweepDone(app)
        XCTAssertEqual(done.gateways, 0)
        XCTAssertEqual(done.answered + done.unanswered, 3,
                       "dash answered, plain and slow did not: \(done)")
        // Not vacuous: the sweep really probed, and rejected, the web page.
        // (A first version passed here with every peer filtered out.)
        let probed = try await dashboardState()["paths"] as? [String] ?? []
        XCTAssertTrue(probed.contains { $0.hasPrefix("dash.tail-scale.ts.net GET /manifest.json") },
                      "dash must have been probed and rejected: \(probed.prefix(5))")

        // "Search again" really sweeps again: dash is probed anew.
        try await resetFakes()
        element(app, "gateway-refresh").tap()
        var reprobed = false
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(500))
            let paths = try await dashboardState()["paths"] as? [String] ?? []
            if paths.contains(where: { $0.hasPrefix("dash.tail-scale.ts.net GET /manifest.json") }) { reprobed = true; break }
        }
        XCTAssertTrue(reprobed, "Search again probes the tailnet again")

        // A host the tailnet does not carry is refused: it would load direct
        // and become the sign-in origin (M5 review).
        let field = element(app, "gateway-manual-field")
        field.tap()
        field.typeText("example.com")
        element(app, "gateway-manual-use").tap()
        XCTAssertTrue(element(app, "gateway-manual-error").waitForExistence(timeout: 5),
                      "a public host is refused, with a reason")
        XCTAssertTrue(element(app, "gateway-picker").exists, "and the picker stays")
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 20))
        field.typeText("dash")
        element(app, "gateway-manual-use").tap()

        // dash.tail-scale.ts.net is the fake dashboard: it reports itself.
        var loaded = false
        for _ in 0..<60 {
            let reports = try await dashboardState()["reports"] as? [String: Any] ?? [:]
            if reports["dash.tail-scale.ts.net"] != nil { loaded = true; break }
            try await Task.sleep(for: .milliseconds(500))
        }
        XCTAssertTrue(loaded, "the manually entered gateway (qualified to its FQDN) loads")
    }

    /// The choice persists: a relaunch goes straight to the gateway, with no
    /// picker.
    func testTheChosenGatewayPersistsAcrossRelaunch() async throws {
        try await resetHarness()
        let app = launch()
        XCTAssertTrue(element(app, "token-sheet").waitForExistence(timeout: 75), "first run: chosen and loaded")
        app.terminate()

        try await resetFakes()
        let again = XCUIApplication()
        again.launchArguments = ["-TestControlURL", Self.controlURL]   // no reset this time
        again.launch()
        defer { again.terminate() }
        XCTAssertTrue(element(again, "token-sheet").waitForExistence(timeout: 60),
                      "the saved gateway loads")
        // Proof it was the SAVED choice: no discovery ran. A sweep would have
        // probed the web-page peer and asked the gateway for its manifest
        // first; re-discovering and auto-choosing gw would otherwise look
        // exactly like persistence (M5 review).
        let dashPaths = try await dashboardState()["paths"] as? [String] ?? []
        XCTAssertFalse(dashPaths.contains { $0.contains("/manifest.json") },
                       "no sweep on a relaunch: dash was probed \(dashPaths.prefix(5))")
        // The page itself fetches /manifest.json (index.html links it), so
        // the mark of a probe is ORDER: a probe asks for the manifest before
        // anything else, a page load starts with GET /.
        let requests = try await gatewayState()["requests"] as? [String] ?? []
        XCTAssertEqual(requests.first, "GET /",
                       "the saved gateway was loaded directly, not probed first: \(requests.prefix(6))")
    }

    /// M5.5: the chosen gateway is gone from the tailnet. The banner's Find
    /// runs a FRESH sweep (not the first run's stale result), and the choice
    /// is applied once the sheet has gone -- the new gateway's token sheet
    /// must still appear, not collide with the closing picker (M5 review).
    func testFindFromTheUnreachableBannerSwitchesGateway() async throws {
        try await resetHarness()
        let app = XCUIApplication()
        app.launchArguments = ["-UITestResetWorkspaces", "-TestControlURL", Self.controlURL,
                               "-UITestHomePage", "https://gone.tail-scale.ts.net"]
        app.launch()
        defer { app.terminate() }

        let find = element(app, "gateway-unreachable-find-button")
        XCTAssertTrue(find.waitForExistence(timeout: 60), "a gateway not in the tailnet: the banner offers Find")
        find.tap()
        let gw = element(app, "gateway-\(Self.gatewayHost)")
        XCTAssertTrue(gw.waitForExistence(timeout: 15), "Find sweeps and lists the gateway")
        gw.tap()
        XCTAssertTrue(element(app, "token-sheet").waitForExistence(timeout: 45),
                      "the new gateway loads, and its token sheet appears after the picker has gone")
        XCTAssertTrue(element(app, "token-sheet-target").label.hasSuffix(Self.gatewayHost))
    }

    /// The device-check rehearsal (DEVICE-CHECK.md §3-4). On the real tailnet
    /// a new node lands in a purgatory range with no grants: it connects but
    /// reaches nothing. Olof then moves its address into the kiro-clients
    /// range WHILE IT RUNS (O3b) and taps Search again. Two things had never
    /// been seen before this test: what the picker shows while the node
    /// reaches nothing, and whether the app, its relay and tsnet keep working
    /// after the control plane changes the running node's own address. The
    /// harness's purgatory jails the app's node at every peer (the peers stay
    /// visible; every SYN is dropped), and /move gives it 100.99.1.7.
    func testDeviceCheckRehearsalPurgatoryThenAddressMove() async throws {
        try await resetHarness(purgatory: true)
        let app = launch()
        defer { app.terminate() }

        // 1. In purgatory: the sweep ends, in bounded time, with nothing.
        // The wait here spans the node's start-up too; the sweep's own
        // timing is R26's app-logged instrument, which the script enforces.
        XCTAssertTrue(element(app, "gateway-picker").waitForExistence(timeout: 60), "the first-run picker")
        let shown = ContinuousClock.now
        let none = element(app, "gateway-none")
        XCTAssertTrue(none.waitForExistence(timeout: 20),
                      "the sweep finishes with no gateway; it must not hang on dropped SYNs")
        let waited = ContinuousClock.now - shown
        let message = none.label
        // The peers are visible (as admin devices plausibly are on the real
        // tailnet), so it is the "checked N" form, not "No computer on your
        // tailnet could be a gateway", which needs an empty candidate list.
        // The wording is F4 §3.5's, which replaced "answered among N".
        XCTAssertTrue(message.hasPrefix("Checked 4 computers"),
                      "in purgatory the picker says: \(message)")
        XCTAssertTrue(message.contains("4 didn't answer at all"),
                      "and every one of them was dropped, not merely uninteresting: \(message)")
        // Purgatory is precisely the situation F4's unanswered-branch advice was
        // written for, so it must be the branch shown: the device is not allowed
        // to reach the peers yet, and searching again cannot change that.
        let advice = element(app, "gateway-none-hint").label
        XCTAssertTrue(advice.contains("isn't allowed to reach"),
                      "the advice must name the real cause, not suggest retrying: \(advice)")
        let done = try sweepDone(app)
        XCTAssertEqual(done.gateways, 0)
        XCTAssertEqual(done.unanswered, 4, "all four were dropped: \(done)")
        XCTAssertFalse(element(app, "gateway-proxy-unhealthy").exists,
                       "the node's loopback is fine; it is the tailnet that drops the traffic")
        let node = try await appNode()
        XCTAssertTrue(node.jailed, "the harness jails the app's node: \(node)")
        XCTAssertFalse(node.addresses.contains { $0.hasPrefix("100.99.1.") },
                       "a new node lands outside the clients range: \(node.addresses)")
        // Not vacuous: the probes went out and nothing accepted them -- no
        // peer journaled a connection from the app (a dropped SYN is never
        // accepted; a refusal would not be journaled either, but the sweep
        // log's timing tells those apart).
        let before = try await harnessState()["journal"] as? [[String: Any]] ?? []
        XCTAssertFalse(before.contains { Self.isFrom(node.addresses, $0) },
                       "no peer accepted a connection from the jailed node: \(before)")
        XCTContext.runActivity(named: "purgatory: picker showed \(message) after \(waited)") { _ in }

        // 2. O3b: the admin moves the running node into the clients range.
        // The netmap lands within a moment on loopback; Olof's tap comes
        // seconds after the console.
        let to = "100.99.1.7"
        let reply = try JSONSerialization.jsonObject(
            with: try await Self.post("\(Self.harnessAPI)/move?hostname=\(node.hostname)&to=\(to)")) as? [String: Any] ?? [:]
        XCTAssertEqual(reply["moved"] as? Int, 1, "the node was moved: \(reply)")
        try await Task.sleep(for: .seconds(2))
        // Search again, as the runbook has Olof do -- and, as it tells him,
        // once more if a search still finds nothing, rather than reading a
        // single miss as a fault. Found means the gateway row, or already
        // the token sheet: the only gateway on a first run is chosen by
        // itself when the sweep ends (M5.3), about 1.5 s after it is listed
        // (the slow peer's timeout), too brief to catch the row reliably.
        // The sighting is recorded; the proof is what follows.
        let row = element(app, "gateway-\(Self.gatewayHost)")
        let sheet = element(app, "token-sheet")
        var listed = false
        var taps = 0
        repeat {
            element(app, "gateway-refresh").tap()
            taps += 1
            for _ in 0..<40 {
                listed = row.exists || sheet.exists
                if listed { break }
                try await Task.sleep(for: .milliseconds(250))
            }
        } while !listed && taps < 2 && element(app, "gateway-refresh").exists
        XCTAssertTrue(sheet.waitForExistence(timeout: 45),
                      "after the move, Search again finds the gateway, it loads over the tailnet, and asks for a token")
        XCTAssertTrue(element(app, "token-sheet-target").label.hasSuffix(Self.gatewayHost))
        XCTAssertFalse(element(app, "nav-error-overlay").exists, "no navigation error after the address change")
        XCTContext.runActivity(named: "after the move: gateway found = \(listed) after \(taps) tap(s) of Search again") { _ in }

        // 3. The traffic crossed the tailnet from the NEW address: the gw
        // peer journals every connection with its tailnet source. Nothing
        // ever came from the purgatory address (the IPv6 address stays).
        let oldV4 = node.addresses.filter { $0.contains(".") }
        let journal = try await harnessState()["journal"] as? [[String: Any]] ?? []
        XCTAssertTrue(journal.contains { $0["peer"] as? String == "gw" && $0["error"] == nil && Self.isFrom([to], $0) },
                      "gw journaled the app from \(to): \(journal.suffix(6))")
        XCTAssertFalse(journal.contains { Self.isFrom(oldV4, $0) },
                       "nothing came from the purgatory address \(oldV4): \(journal)")
        let after = try await appNode()
        XCTAssertFalse(after.jailed, "released: \(after)")
        XCTAssertTrue(after.addresses.contains(to), "control holds the new address: \(after.addresses)")

        // 4. The app's own view agrees: Status shows the moved address, not
        // the old one (the 5 s status poll has long since run).
        element(app, "token-sheet-close").tap()
        let list = app.openStatus()
        let addresses = app.statusRow("diag-addresses", in: list)
        XCTAssertTrue(addresses.contains(to), "Status shows the moved address: \(addresses)")
        XCTAssertFalse(oldV4.contains { addresses.contains($0) }, "and not the old one: \(addresses)")
    }

    // MARK: - F7: honest counts, the tail of a large tailnet, and the declined

    /// A sweep that runs out of time says so, and names only what it probed.
    ///
    /// Before F7 the picker reported `candidateCount` as "checked", so on a
    /// large tailnet it claimed to have checked forty-three machines when the
    /// 12 s deadline let it check about half that.
    func testATruncatedSweepSaysSoAndCountsOnlyWhatItProbed() async throws {
        try await resetHarness(withGateway: false)
        // Ninety, not forty. A 12 s deadline at concurrency 12 and a 4 s probe
        // timeout reaches about 36 candidates, so 43 sat right on the boundary
        // and the first run of this test probed all 43 and did not truncate —
        // while a 44-candidate run in the same suite truncated at 40. Measured,
        // not estimated: the app logged `probed=43/43 truncated=no` beside
        // `probed=40/44 truncated=yes`. A test whose subject is a coin flip is
        // worse than no test, so this is now three times the boundary.
        try await addPeers(90)
        let total = try await harnessPeerCount()
        XCTAssertGreaterThan(total, 80, "the harness should be presenting a large tailnet")

        let app = launch()
        defer { app.terminate() }
        XCTAssertTrue(element(app, "gateway-picker").waitForExistence(timeout: 60))
        XCTAssertTrue(element(app, "gateway-none").waitForExistence(timeout: 40),
                      "the sweep finished and found nothing")

        let text = element(app, "gateway-none").label
        XCTAssertTrue(text.contains("ran out of time"),
                      "a truncated sweep must say so; got: \(text)")
        guard let counts = checkedCounts(text) else {
            return XCTFail("the empty state names no counts: \(text)")
        }
        XCTAssertEqual(counts.total, total,
                       "the total must be every candidate on the tailnet; got: \(text)")
        XCTAssertLessThan(counts.probed, counts.total,
                          "it cannot have probed them all in 12 s; got: \(text)")
        // The counts on screen are the counts the sweep actually recorded.
        let done = try sweepDone(app)
        XCTAssertEqual(done.answered + done.unanswered, counts.probed,
                       "answered + unanswered must be exactly what it claims to have checked: \(done)")
        XCTAssertTrue(element(app, "gateway-refresh").label.contains("Keep searching"),
                      "and the button offers to continue, not to start over")
    }

    /// A finished sweep says it checked them all, and does not cry wolf.
    ///
    /// The other half of the rule above: a deadline that arrives with every
    /// verdict in hand is an ordinary sweep, not a truncated one.
    func testAFinishedSweepSaysItCheckedThemAll() async throws {
        try await resetHarness(withGateway: false)
        try await addPeers(3)
        let total = try await harnessPeerCount()

        let app = launch()
        defer { app.terminate() }
        XCTAssertTrue(element(app, "gateway-picker").waitForExistence(timeout: 60))
        XCTAssertTrue(element(app, "gateway-none").waitForExistence(timeout: 40))

        let text = element(app, "gateway-none").label
        XCTAssertFalse(text.contains("ran out of time"),
                       "a sweep that checked everything must not claim it ran out of time: \(text)")
        let counts = checkedCounts(text)
        XCTAssertEqual(counts?.probed, total, "it checked them all: \(text)")
        XCTAssertEqual(counts?.total, total)
        let done = try sweepDone(app)
        XCTAssertEqual(done.answered + done.unanswered, total, "\(done)")
        XCTAssertEqual(element(app, "gateway-refresh").label, "Search again",
                       "nothing was left, so the button starts over rather than continuing")
    }

    /// Keep searching resumes at the cursor, so the tail of a large tailnet is
    /// reached rather than the first two rounds being re-probed forever.
    ///
    /// What this asserts is that the **counts complete**: a truncated sweep says
    /// "Checked 40 of 44", and after one tap the picker says it checked all 44.
    /// A picker that restarted from the top would report the same partial count
    /// however many times the button was tapped, which is the defect F7 §4.3
    /// exists to fix.
    ///
    /// It deliberately does **not** assert that the gateway at the tail then
    /// loads, though that is the owner-visible point of §4.3. With this fixture
    /// it cannot: forty peers that are reported online with no data plane behind
    /// them congest tsnet enough that a probe to the *reachable* gateway also
    /// exceeds its 4 s budget — measured, `socks[41] CONNECT gw…:443` reached the
    /// proxy and never completed. That is a fixture artefact more than a product
    /// fault: a real tailnet reports an unreachable peer as **offline**, and
    /// `exclusion` drops offline peers before they are ever probed. The one real
    /// environment that can produce many online-but-unreachable peers is a
    /// restricted tailnet like the author's own during device purgatory, which
    /// is recorded as an open question in F7 §8 rather than asserted here.
    func testSearchAgainContinuesFromWhereItStopped() async throws {
        try await resetHarness()
        // Ninety, for the same reason as the truncation test: 40 put the sweep
        // right on the 12 s boundary, and one run of this test probed all 44
        // candidates and never truncated at all.
        try await addPeers(90)
        let total = try await harnessPeerCount()

        let app = launch()
        defer { app.terminate() }
        XCTAssertTrue(element(app, "gateway-picker").waitForExistence(timeout: 60))
        XCTAssertTrue(element(app, "gateway-none").waitForExistence(timeout: 40),
                      "the first sweep runs out of time")
        let first = element(app, "gateway-none").label
        XCTAssertTrue(first.contains("ran out of time"), "got: \(first)")
        guard var probed = checkedCounts(first)?.probed else {
            return XCTFail("the empty state names no counts: \(first)")
        }
        XCTAssertLessThan(probed, total, "it did not reach them all: \(first)")

        // Tap until the list is exhausted, asserting the count STRICTLY climbs
        // each time. That is the whole of §4.3: a picker that restarted from the
        // top would report the same partial count for ever, so monotone progress
        // is the property, and reaching the total is the proof it terminates.
        // Ninety candidates at ~36 a sweep needs three; five is the ceiling.
        var text = first
        for tap in 1...5 {
            let button = element(app, "gateway-refresh")
            XCTAssertTrue(button.label.contains("Keep searching"),
                          "tap \(tap): a truncated sweep offers to continue, not to restart: \(button.label)")
            button.tap()
            var advanced = false
            for _ in 0..<60 {
                try await Task.sleep(for: .milliseconds(500))
                // The row exists only while `phase == .finished`, so it
                // disappears for the duration of the sweep the tap just started
                // — reading `.label` through the gap throws "no matches found".
                // Its presence with a higher count is therefore exactly the
                // signal wanted: the next sweep has finished and got further.
                let row = element(app, "gateway-none")
                guard row.exists else { continue }
                text = row.label
                if let c = checkedCounts(text), c.probed > probed { advanced = true; break }
            }
            XCTAssertTrue(advanced,
                          "tap \(tap): the count must climb past \(probed), not restart: \(text)")
            guard let c = checkedCounts(text) else {
                return XCTFail("tap \(tap): the empty state names no counts: \(text)")
            }
            XCTAssertEqual(c.total, total, "tap \(tap): the total must not shrink: \(text)")
            probed = c.probed
            if !text.contains("ran out of time") { break }
        }
        XCTAssertFalse(text.contains("ran out of time"),
                       "continuing must eventually exhaust the list: \(text)")
        XCTAssertEqual(probed, total,
                       "and every candidate has been probed across the chain: \(text)")
        XCTAssertEqual(element(app, "gateway-refresh").label, "Search again",
                       "so the button goes back to offering a fresh search")
    }

    /// A gateway declined for its OS is offered, with the reason, and one tap
    /// probes it.
    ///
    /// `synology` is a real example: a gateway on a NAS. R26's OS filter is a
    /// cheap-probe optimisation, and on the author's tailnet it cannot misfire
    /// — every gateway of his runs Linux or macOS.
    func testAPeerSkippedForItsOSIsOfferedAndCanBeProbed() async throws {
        try await resetHarness()
        try await setPeerOS("gw", "synology")

        let app = launch()
        defer { app.terminate() }
        XCTAssertTrue(element(app, "gateway-picker").waitForExistence(timeout: 60))
        XCTAssertTrue(element(app, "gateway-none").waitForExistence(timeout: 40),
                      "the sweep finds nothing, because the only gateway was filtered out")

        let summary = element(app, "gateway-skipped-summary")
        XCTAssertTrue(summary.waitForExistence(timeout: 5), "the declined peer is offered, not hidden")
        XCTAssertEqual(summary.label, "1 computer was not checked")
        summary.tap()

        let row = element(app, "gateway-skipped-\(Self.gatewayHost)")
        XCTAssertTrue(row.waitForExistence(timeout: 5), "and it names the host")
        XCTAssertTrue(row.label.contains("OS synology"), "with the reason: \(row.label)")
        row.tap()

        // Probed anyway, it answers, and it is a gateway like any other.
        let found = element(app, "gateway-\(Self.gatewayHost)")
        XCTAssertTrue(found.waitForExistence(timeout: 30), "one tap probes it and it answers")
        found.tap()
        XCTAssertTrue(element(app, "token-sheet").waitForExistence(timeout: 75),
                      "and choosing it loads the gateway")
    }

    /// The same, for a gateway owned by someone else — a colleague's or a
    /// family member's machine on a shared tailnet, which is the case the
    /// author's own tailnet can never produce.
    func testAGatewayOwnedByAnotherUserIsOffered() async throws {
        try await resetHarness()
        try await setPeerOwner("gw", 777)

        let app = launch()
        defer { app.terminate() }
        XCTAssertTrue(element(app, "gateway-picker").waitForExistence(timeout: 60))
        XCTAssertTrue(element(app, "gateway-none").waitForExistence(timeout: 40))

        let summary = element(app, "gateway-skipped-summary")
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        summary.tap()
        let row = element(app, "gateway-skipped-\(Self.gatewayHost)")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.label.contains("another owner"), "with the reason: \(row.label)")
        row.tap()
        XCTAssertTrue(element(app, "gateway-\(Self.gatewayHost)").waitForExistence(timeout: 30),
                      "probed anyway, a colleague's gateway answers like any other")
    }

    // MARK: - F16: a loopback that accepts and never answers

    /// The node's own loopback goes silent before the first sweep starts
    /// (`-UITestStallLoopback`, with delay 0 so it lands before the status that
    /// starts the sweep). Every probe rides that listener, so none answers; the
    /// sweep then asks the loopback itself, and that question is bounded at 3 s
    /// (F16 §4.1). So the picker leaves "Searching…" for P6 within seconds.
    /// Before F16 the question waited out TailscaleKit's 60 s timeout, and the
    /// picker read "Searching…" for about 64-72 s: the owner's "scan didn't
    /// work" of 2026-09-24. The exact "Status request abandoned after 3 s" log
    /// line is checked by scripts/test-discovery.sh from the unified log.
    func testAStalledLoopbackEndsTheSearchWithinSeconds() async throws {
        try await resetHarness()
        let app = launch(extra: ["-UITestStallLoopback", "-UITestTCPChaosDelay", "0"])
        defer { app.terminate() }

        XCTAssertTrue(element(app, "gateway-searching").waitForExistence(timeout: 60), "the sweep starts")
        let searchingAt = Date()
        XCTAssertTrue(element(app, "gateway-proxy-unhealthy").waitForExistence(timeout: 30),
                      "the sweep ends in P6: nothing answered, and neither did the node's own proxy")
        let took = Date().timeIntervalSince(searchingAt)
        XCTAssertLessThanOrEqual(took, 16, "P6 within 16 s of the search starting, not about a minute (\(took) s)")
        XCTAssertNotEqual(element(app, "gateway-refresh").label, "Searching…", "and the button no longer says so")
        // Not vacuous: the stall came before the sweep, so no probe got an
        // answer. A probe that got through would make this a different test.
        let done = try sweepDone(app)
        XCTAssertEqual(done.answered, 0, "no probe crossed a silent loopback: \(done)")
        XCTAssertEqual(done.unanswered, 4, "all four peers were tried: \(done)")
        print("F16 DISCOVERY: searching -> P6 \(String(format: "%.1f", took)) s")
    }

    /// The same silent loopback, then what repairs it: two abandoned status
    /// requests in a row (the sweep's own and the 5 s poll's) replace the
    /// loopback as a refused one is replaced, with nothing tapped. The hook's
    /// stall belongs to the listener it marked, and the replacement is
    /// unmarked, so it is the recovery that makes the next search work, and
    /// the gateway is found, chosen by itself and loaded.
    func testAStalledLoopbackIsReplacedAndTheSearchThenFindsTheGateway() async throws {
        try await resetHarness()
        let app = launch(extra: ["-UITestStallLoopback", "-UITestTCPChaosDelay", "0"])
        defer { app.terminate() }

        XCTAssertTrue(element(app, "gateway-searching").waitForExistence(timeout: 60), "the sweep starts")
        let searchingAt = Date()
        XCTAssertTrue(element(app, "gateway-proxy-unhealthy").waitForExistence(timeout: 30), "the stalled sweep ends in P6")

        // "recovered" is set by the loopback recovery and nothing else.
        let chaos = element(app, "tcp-chaos-test-status")
        var recoveredAfter: TimeInterval?
        while Date().timeIntervalSince(searchingAt) < 30 {
            if chaos.exists, chaos.label == "recovered" {
                recoveredAfter = Date().timeIntervalSince(searchingAt)
                break
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        let recovered = try XCTUnwrap(recoveredAfter,
            "the loopback is replaced with nothing tapped (status: \(chaos.exists ? chaos.label : "absent"))")
        XCTAssertLessThanOrEqual(recovered, 25, "within 25 s of the search starting (\(recovered) s)")

        try await resetFakes()
        element(app, "gateway-refresh").tap()
        let sheet = element(app, "token-sheet")
        XCTAssertTrue(sheet.waitForExistence(timeout: 75),
                      "the search over the replaced loopback finds the gateway, chooses it and loads it")
        XCTAssertTrue(element(app, "token-sheet-target").label.hasSuffix(Self.gatewayHost))
        let requests = try await gatewayState()["requests"] as? [String] ?? []
        XCTAssertEqual(requests.first, "GET /manifest.json", "the gateway was probed after the recovery: \(requests.prefix(3))")
        print("F16 DISCOVERY: searching -> loopback recovered \(String(format: "%.1f", recovered)) s")
    }

    // MARK: - F5 §7: the gateway switcher in Settings

    /// Two known gateways, dash (the fake dashboard, current) and gw: Settings
    /// names the current one, labels gw from a sweep within R39's first-result
    /// budget, and one tap loads it -- proved by gw's own request log. A
    /// relaunch keeps the list, now with dash as the other gateway.
    func testTheSwitcherListsTheCurrentGatewayAndSwitchesToAnother() async throws {
        try await resetHarness()
        let app = launch(extra: ["-UITestHomePage", "https://dash.tail-scale.ts.net",
                                 "-UITestKnownGateways", "https://dash.tail-scale.ts.net,https://\(Self.gatewayHost)"])
        try await waitForDashPage()
        try openSettings(app)
        XCTAssertEqual(element(app, "gateway-current").value as? String, "dash.tail-scale.ts.net",
                       "Settings names the gateway in use")
        let row = element(app, "gateway-switch-\(Self.gatewayHost)")
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the other known gateway has a row")
        let shown = ContinuousClock.now
        XCTAssertTrue(waitForValue(row, "answering", timeout: 15), "gw is labelled answering: \(row.value ?? "nil")")
        XCTAssertLessThanOrEqual(ContinuousClock.now - shown, .seconds(5), "within R39's first-result budget")

        try await resetFakes()
        row.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForNonExistence(timeout: 10), "a switch closes Settings")
        XCTAssertTrue(element(app, "token-sheet").waitForExistence(timeout: 45), "gw loads and asks for a token")
        let requests = try await gatewayState()["requests"] as? [String] ?? []
        XCTAssertTrue(requests.contains("GET /"), "gw's own log has the page load: \(requests.prefix(6))")
        app.terminate()

        let again = XCUIApplication()
        again.launchArguments = ["-TestControlURL", Self.controlURL]   // the same workspace
        again.launch()
        defer { again.terminate() }
        let sheet = element(again, "token-sheet")
        XCTAssertTrue(sheet.waitForExistence(timeout: 60), "the relaunch opens gw")
        element(again, "token-sheet-close").tap()
        try openSettings(again)
        XCTAssertEqual(element(again, "gateway-current").value as? String, Self.gatewayHost, "gw is current after a relaunch")
        XCTAssertTrue(element(again, "gateway-switch-dash.tail-scale.ts.net").waitForExistence(timeout: 5),
                      "and dash is remembered")
    }

    /// A known gateway that does not answer (plain serves nothing) says so
    /// once the sweep ends, and stays tappable: the label is a forecast, and
    /// F4 reports the real load, with its way to another gateway.
    func testAKnownGatewayThatDoesNotAnswerIsLabelledAndF4ShowsIt() async throws {
        try await resetHarness()
        let app = launch(extra: ["-UITestHomePage", "https://dash.tail-scale.ts.net",
                                 "-UITestKnownGateways", "https://dash.tail-scale.ts.net,https://plain.tail-scale.ts.net"])
        defer { app.terminate() }
        try await waitForDashPage()
        try openSettings(app)
        let row = element(app, "gateway-switch-plain.tail-scale.ts.net")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForValue(row, "not answering", timeout: 20), "labelled once the sweep ends: \(row.value ?? "nil")")
        XCTAssertTrue(row.isEnabled, "and still tappable")
        row.tap()
        XCTAssertTrue(element(app, "nav-error-overlay").waitForExistence(timeout: 45), "F4: the failed load is shown")
        XCTAssertTrue(element(app, "nav-error-choose-gateway").exists, "with a way to another gateway")
    }

    /// A known gateway the tailnet does not carry cannot be chosen: it would
    /// load direct, off the tailnet, and become the sign-in origin.
    func testAKnownGatewayOffTheTailnetCannotBeChosen() async throws {
        try await resetHarness()
        let app = launch(extra: ["-UITestHomePage", "https://dash.tail-scale.ts.net",
                                 "-UITestKnownGateways", "https://dash.tail-scale.ts.net,https://gateway.example.com"])
        defer { app.terminate() }
        try await waitForDashPage()
        try openSettings(app)
        let row = element(app, "gateway-switch-gateway.example.com")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertEqual(row.value as? String, "not on this tailnet")
        XCTAssertFalse(row.isEnabled, "the row is disabled")
        row.tap()
        try await Task.sleep(for: .seconds(2))
        XCTAssertTrue(app.navigationBars["Settings"].exists, "a tap does nothing: Settings stays")
        XCTAssertEqual(element(app, "gateway-current").value as? String, "dash.tail-scale.ts.net", "and dash is still current")
    }

    /// The fake dashboard has reported a page from dash over the tailnet.
    private func waitForDashPage() async throws {
        for _ in 0..<120 {
            let reports = try await dashboardState()["reports"] as? [String: Any] ?? [:]
            if reports["dash.tail-scale.ts.net"] != nil { return }
            try await Task.sleep(for: .milliseconds(500))
        }
        XCTFail("dash never loaded")
    }

    /// The gear, then Settings; the app bar may need a pull to show it (F15).
    private func openSettings(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) throws {
        let gear = app.buttons["settings-button"].firstMatch
        XCTAssertTrue(gear.waitForExistence(timeout: 10), "the gear exists", file: file, line: line)
        if !gear.isHittable {
            let web = app.webViews.firstMatch
            web.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
                .press(forDuration: 0.05, thenDragTo: web.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)))
        }
        gear.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10), "Settings opens", file: file, line: line)
    }

    /// Polls an element's accessibility value.
    private func waitForValue(_ element: XCUIElement, _ want: String, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "value == %@", want)
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)],
                                timeout: timeout) == .completed
    }

    // MARK: - Helpers

    private func launch(extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestResetWorkspaces", "-TestControlURL", Self.controlURL] + extra
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func resetHarness(withGateway: Bool = true, purgatory: Bool = false) async throws {
        var query: [String] = []
        if !withGateway { query.append("gw=0") }
        if purgatory { query.append("purgatory=1") }
        let suffix = query.isEmpty ? "" : "?" + query.joined(separator: "&")
        let data = try await Self.post("\(Self.harnessAPI)/reset\(suffix)", timeout: 90)
        let state = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        XCTAssertNotNil(state["generation"], "reset failed: \(String(decoding: data, as: UTF8.self))")
    }

    private func harnessState() async throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: try await Self.get("\(Self.harnessAPI)/state")) as? [String: Any] ?? [:]
    }

    // MARK: - F7: a large tailnet, and peers a filter declined

    /// Adds `n` synthetic peers: in the netmap, candidates by every one of
    /// R26's filters, and with **nothing behind them**, so a probe stalls until
    /// the app's own 4 s request timeout. That is what makes a sweep that runs
    /// out of time reproducible without standing up forty real tsnet nodes.
    ///
    /// `name` matters: the candidate list is alphabetical after the saved
    /// gateway, so `a` puts them all *before* `gw` and the gateway is out of
    /// reach of a first sweep. The harness's default prefix sorts after it.
    @discardableResult
    private func addPeers(_ n: Int, name: String = "a", os: String? = nil) async throws -> [String] {
        var url = "\(Self.harnessAPI)/peers?n=\(n)&name=\(name)"
        if let os { url += "&os=\(os)" }
        let data = try await Self.post(url, timeout: 30)
        let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        XCTAssertEqual(reply["added"] as? Int, n, "the harness did not add them: \(reply)")
        return reply["hostnames"] as? [String] ?? []
    }

    /// Makes an existing peer report a different OS — `synology`, a NAS, which
    /// R26's OS filter declines and F7 must offer anyway.
    private func setPeerOS(_ hostname: String, _ os: String) async throws {
        let data = try await Self.post("\(Self.harnessAPI)/peer-os?hostname=\(hostname)&os=\(os)")
        let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        XCTAssertEqual(reply["updated"] as? Int, 1, "no peer named \(hostname): \(reply)")
    }

    /// Gives an existing peer a different, non-zero owner — a colleague's
    /// machine on a shared tailnet. Zero is what the app reads as "owner
    /// unknown", which does *not* exclude, so the harness refuses it.
    private func setPeerOwner(_ hostname: String, _ user: Int) async throws {
        let data = try await Self.post("\(Self.harnessAPI)/peer-owner?hostname=\(hostname)&user=\(user)")
        let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        XCTAssertEqual(reply["updated"] as? Int, 1, "no peer named \(hostname): \(reply)")
    }

    private struct SweepDone: CustomStringConvertible {
        let gateways: Int, answered: Int, unanswered: Int
        var description: String { "gateways=\(gateways) answered=\(answered) unanswered=\(unanswered)" }
    }

    /// The hidden `sweep-done:<gateways>:<answered>:<unanswered>` marker.
    private func sweepDone(_ app: XCUIApplication) throws -> SweepDone {
        let label = element(app, "gateway-sweep-done").label
        let f = label.split(separator: ":").map(String.init)
        guard f.count == 4, f[0] == "sweep-done",
              let g = Int(f[1]), let a = Int(f[2]), let u = Int(f[3])
        else {
            XCTFail("unreadable sweep marker: \(label)")
            return SweepDone(gateways: 0, answered: 0, unanswered: 0)
        }
        return SweepDone(gateways: g, answered: a, unanswered: u)
    }

    /// "Checked 24 of 43 computers in 12 s — …" → (24, 43). Reads the count the
    /// owner reads, which is the whole point of F7 §4.2.
    private func checkedCounts(_ text: String) -> (probed: Int, total: Int)? {
        // "Checked P of N computers" when truncated, "Checked N computers" when not.
        let words = text.replacingOccurrences(of: ",", with: " ").split(separator: " ").map(String.init)
        guard let i = words.firstIndex(of: "Checked") else { return nil }
        if words.count > i + 2, words[i + 2] == "of", let p = Int(words[i + 1]),
           words.count > i + 3, let n = Int(words[i + 3]) {
            return (p, n)
        }
        if words.count > i + 1, let n = Int(words[i + 1]) { return (n, n) }
        return nil
    }

    /// How many peers the harness is presenting, the app's own node excluded.
    /// Every harness peer and every synthetic one passes R26's filters, so this
    /// is also the candidate count — which is what the picker's total must be.
    private func harnessPeerCount() async throws -> Int {
        let nodes = try await harnessState()["nodes"] as? [[String: Any]] ?? []
        return nodes.filter { $0["harnessPeer"] as? Bool == true }.count
    }

    private struct Node {
        let hostname: String
        let addresses: [String]
        let jailed: Bool
    }

    /// The one node that is not the harness's own: the app's. Waits for it
    /// to register.
    private func appNode() async throws -> Node {
        var last: [[String: Any]] = []
        for _ in 0..<60 {
            last = try await harnessState()["nodes"] as? [[String: Any]] ?? []
            let apps = last.filter { $0["harnessPeer"] as? Bool == false }
            XCTAssertLessThanOrEqual(apps.count, 1, "expected one app node, found \(apps.count): \(apps)")
            if let n = apps.first {
                return Node(hostname: n["hostname"] as? String ?? "",
                            addresses: n["addresses"] as? [String] ?? [],
                            jailed: n["jailed"] as? Bool ?? false)
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        XCTFail("the app's node never registered with the harness; nodes: \(last)")
        return Node(hostname: "", addresses: [], jailed: false)
    }

    /// Whether a journal entry's tailnet source is one of `addresses`.
    private static func isFrom(_ addresses: [String], _ entry: [String: Any]) -> Bool {
        let from = entry["from"] as? String ?? ""
        return addresses.contains { from.hasPrefix("\($0):") || from.hasPrefix("[\($0)]:") }
    }

    private func gatewayState() async throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: try await Self.get("\(Self.gatewayControl)/__state")) as? [String: Any] ?? [:]
    }

    private func dashboardState() async throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: try await Self.get("\(Self.dashboardControl)/__state")) as? [String: Any] ?? [:]
    }

    // Both go through HarnessControl (UITestSupport.swift), which fails on any
    // non-2xx — including a control endpoint that does not exist.
    private static func get(_ url: String) async throws -> Data {
        try await HarnessControl.get(url)
    }

    @discardableResult
    private static func post(_ url: String, timeout: TimeInterval = 5) async throws -> Data {
        try await HarnessControl.post(url, timeout: timeout)
    }
}
