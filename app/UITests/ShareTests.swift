// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

//
//  ShareTests.swift
//  LatchkeyUITests
//
//  F3 stage 1: sharing into a session, against KiroCrew's REAL pinned 0.7.1
//  frontend and the fake gateway's share routes (F3 §7, session rows).
//
//  Links enter the way the owner's Shortcut and any other app enter them:
//  `latchkey://share?…`, opened by the system. Documents enter through the
//  test hook `-UITestSeedShare`, which writes exactly what the App Intent
//  writes; XCUITest can drive neither the intent nor a share sheet, so the
//  capture side is the device check's (F3 §7).
//
//  Every outcome is asserted on the SERVER (R13): the fake's posts journal,
//  its upload counters and its violations -- any post naming a slot that was
//  not in the list, which the real gateway would silently create a session
//  for. "Sent" on screen must match a post in the journal.
//
//  Needs the offline harness AND the fake gateway: scripts/test-session.sh.
//

import UIKit
import XCTest

@MainActor
final class ShareTests: XCTestCase {

    static let gatewayControl = SessionTests.gatewayControl
    static let proxyControl = SessionTests.proxyControl
    static let gateway = SessionTests.gateway

    override func setUp() async throws {
        continueAfterFailure = false
        guard (try? await Self.get("\(Self.gatewayControl)/__state")) != nil,
              (try? await Self.get("\(Self.proxyControl)/journal")) != nil
        else {
            XCTFail("The fake gateway or the offline harness is not running. Use scripts/test-session.sh (parent repo).")
            return
        }
        try await HarnessInstance.assertIsOurs("\(Self.gatewayControl)/__state")
        try await HarnessInstance.assertIsOurs("\(Self.proxyControl)/state")
        _ = try await Self.post("\(Self.gatewayControl)/__reset")
        _ = try await Self.post("\(Self.proxyControl)/mode?blackhole=0")
        _ = try await Self.post("\(Self.proxyControl)/open")
    }

    // MARK: - Links

    /// The primary use case: a link shared from another app reaches the
    /// session the owner picks, with its title and URL and the note, and the
    /// dashboard is moved to that session. The note is typed, so the keyboard
    /// comes up over the sheet; the page's frame must be the same afterwards
    /// (F13's black page came from exactly such an inset).
    func testASharedLinkReachesTheChosenSession() async throws {
        let app = try await launchSignedIn()
        defer { app.terminate() }
        let page = app.webViews.firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 10))
        let frameBefore = page.frame
        XCTAssertGreaterThan(frameBefore.height, 200, "the page has a real height to begin with: \(frameBefore)")

        share(app, "latchkey://share?url=https%3A%2F%2Fexample.com%2Fa-XYZ&title=Article%20A")
        try pick(app, "obsidian")
        let note = element(app, "share-note")
        note.tap()
        note.typeText("read this NOTE-XYZ")
        element(app, "share-send").tap()

        let awaited1 = try await lastResult(app)
        XCTAssertEqual(awaited1, "sent:obsidian")
        let state = try await gatewayState()
        let posts = state["posts"] as? [[String: Any]] ?? []
        XCTAssertEqual(posts.count, 1, "one post: \(posts)")
        XCTAssertEqual(posts.first?["slot"] as? String, "obsidian")
        XCTAssertEqual(posts.first?["message"] as? String, "Article A\nhttps://example.com/a-XYZ\n\nread this NOTE-XYZ",
                       "the title, the URL, a blank line, the note (F3 §4.6)")
        XCTAssertEqual(violations(state), 0, "\(state["violations"] ?? [])")
        let navs = state["navigations"] as? [[String: Any]] ?? []
        XCTAssertTrue(navs.contains { $0["sid"] as? String == "obsidian" && $0["prefill"] as? Bool == false },
                      "the dashboard was moved to the session: \(navs)")
        XCTAssertEqual(inboxCount(app), 0, "a confirmed share leaves the inbox")
        XCTAssertTrue(page.waitForExistence(timeout: 5))
        XCTAssertEqual(page.frame, frameBefore, "the share left the page's frame as it was (F13, F15)")
    }

    /// Olof's answer 1: the last session is preselected, and Send posts to it.
    func testTheLastSessionIsPreselected() async throws {
        let app = try await launchSignedIn()
        defer { app.terminate() }
        share(app, "latchkey://share?url=https://example.com/one")
        try pick(app, "notes")
        element(app, "share-send").tap()
        let awaited2 = try await lastResult(app)
        XCTAssertEqual(awaited2, "sent:notes")

        share(app, "latchkey://share?url=https://example.com/two")
        let selected = element(app, "share-destination-selected")
        XCTAssertTrue(element(app, "share-session-notes").waitForExistence(timeout: 30))
        XCTAssertEqual(selected.label, "notes", "the last session is selected before any tap")
        element(app, "share-send").tap()
        let awaited3 = try await lastResult(app)
        XCTAssertEqual(awaited3, "sent:notes")
        let posts = (try await gatewayState())["posts"] as? [[String: Any]] ?? []
        XCTAssertEqual(posts.map { $0["slot"] as? String }, ["notes", "notes"])
    }

    /// The trap (F3 §4.5): the remembered session is gone, so nothing is
    /// selected, the owner is told, and nothing is posted to the stale key --
    /// which the real gateway would have created as a new session.
    func testOnlyAListedSlotIsEverPosted() async throws {
        let app = try await launchSignedIn()
        defer { app.terminate() }
        share(app, "latchkey://share?url=https://example.com/one")
        try pick(app, "obsidian")
        element(app, "share-send").tap()
        let awaited4 = try await lastResult(app)
        XCTAssertEqual(awaited4, "sent:obsidian")

        _ = try await Self.post("\(Self.gatewayControl)/__slots?keys=notes,plan")
        share(app, "latchkey://share?url=https://example.com/two")
        XCTAssertTrue(element(app, "share-session-notes").waitForExistence(timeout: 30))
        XCTAssertEqual(element(app, "share-destination-selected").label, "none", "nothing preselected")
        XCTAssertTrue(element(app, "share-notice").exists, "the owner is told the session is gone")
        XCTAssertFalse(element(app, "share-session-obsidian").exists)
        XCTAssertFalse(element(app, "share-send").isEnabled, "no Send without a pick")
        let state = try await gatewayState()
        XCTAssertEqual(counter(state, "share_posts"), 1, "nothing more was posted")
        XCTAssertEqual(violations(state), 0, "no post to an unlisted slot: \(state["violations"] ?? [])")
    }

    /// A busy session queues the message: said as queued, and the item is
    /// done with (the gateway has it).
    func testABusySlotIsQueuedNotSent() async throws {
        _ = try await Self.post("\(Self.gatewayControl)/__slots?keys=obsidian,notes&busy=obsidian")
        let app = try await launchSignedIn()
        defer { app.terminate() }
        share(app, "latchkey://share?url=https://example.com/q")
        try pick(app, "obsidian")
        element(app, "share-send").tap()
        let awaited5 = try await lastResult(app)
        XCTAssertEqual(awaited5, "queued:obsidian")
        let awaited6 = try await gatewayState()
        XCTAssertEqual(counter(awaited6, "share_posts"), 1)
        XCTAssertEqual(inboxCount(app), 0, "a queued share is confirmed, and leaves the inbox")
    }

    /// The ported-origin CSRF refusal (F1 §4a): a bare 403 is shown as a
    /// refusal, prefill is offered and opens the session with the text, and
    /// the item stays -- the app cannot know it was sent.
    func testARefusedPostOffersPrefill() async throws {
        let app = try await launchSignedIn()
        defer { app.terminate() }
        _ = try await Self.post("\(Self.gatewayControl)/__csrf-deny?on=1")
        share(app, "latchkey://share?url=https://example.com/p&title=P")
        try pick(app, "obsidian")
        element(app, "share-send").tap()
        let result = element(app, "share-result")
        XCTAssertTrue(result.waitForExistence(timeout: 30))
        XCTAssertEqual(result.label, "failed:refused-403")
        element(app, "share-prefill").tap()
        var navs: [[String: Any]] = []
        for _ in 0..<20 {
            navs = (try await gatewayState())["navigations"] as? [[String: Any]] ?? []
            if navs.contains(where: { $0["prefill"] as? Bool == true }) { break }
            try await Task.sleep(for: .milliseconds(500))
        }
        XCTAssertTrue(navs.contains { $0["sid"] as? String == "obsidian" && $0["prefill"] as? Bool == true },
                      "GET /chat?sid=obsidian&prefill=…: \(navs)")
        let awaited7 = try await gatewayState()
        XCTAssertEqual(counter(awaited7, "share_posts"), 0)
        XCTAssertEqual(inboxCount(app), 1, "the item stays")
    }

    /// Signed out between the pick and Send: the sign-in sheet says a share
    /// waits, and after sign-in the share goes by itself -- no second tap.
    ///
    /// The gateway signs out the app's requests alone (/__app-signed-out),
    /// so Send is the first to find the session gone. After __expire the
    /// page found it on its own, about 6 s after the picker listed, and put
    /// the sign-in sheet over Send: Send had to win that race, by 0.09 to
    /// 0.35 s, and the settle wait lost it.
    func testSignedOutMidShareThenResumed() async throws {
        let app = try await launchSignedIn()
        defer { app.terminate() }
        share(app, "latchkey://share?url=https://example.com/s")
        try pick(app, "obsidian")
        let before = try await gatewayState()
        _ = try await Self.post("\(Self.gatewayControl)/__app-signed-out")
        element(app, "share-send").tap()
        XCTAssertTrue(element(app, "token-sheet").waitForExistence(timeout: 30), "the sign-in sheet")
        let waiting = element(app, "share-waiting-count")
        XCTAssertTrue(waiting.waitForExistence(timeout: 5))
        XCTAssertEqual(waiting.label, "1", "it says one share waits for sign-in")
        let refused = try await gatewayState()
        XCTAssertEqual(counter(refused, "share_posts"), 0)
        XCTAssertGreaterThan(counter(refused, "share_denials"), counter(before, "share_denials"),
                             "Send's request was refused as signed out")
        try await signIn(app)
        let awaited9 = try await lastResult(app, timeout: 45)
        XCTAssertEqual(awaited9, "sent:obsidian", "sent without another tap")
        let after = try await gatewayState()
        XCTAssertEqual(counter(after, "share_posts"), 1)
        XCTAssertEqual(counter(after, "denials") - counter(before, "denials"),
                       counter(after, "app_signed_out_denials") - counter(before, "app_signed_out_denials"),
                       "only the app's requests were refused: the page had nothing to notice first")
    }

    /// The inbox is on disk: a share the app was killed before sending is
    /// there after a relaunch.
    func testAColdLaunchKeepsTheItem() async throws {
        var app = try await launchSignedIn()
        share(app, "latchkey://share?url=https://example.com/c&title=Kept%20Title")
        XCTAssertTrue(element(app, "share-session-obsidian").waitForExistence(timeout: 30))
        app.terminate()
        app = launch(reset: false)
        defer { app.terminate() }
        let item = element(app, "share-item")
        XCTAssertTrue(item.waitForExistence(timeout: 45), "the picker comes back after a relaunch")
        XCTAssertTrue(item.label.contains("Kept Title"), item.label)
    }

    // MARK: - Documents

    /// A document is uploaded as the page, then posted as the dashboard's
    /// composer posts one: `[attached_file 1] <the path the gateway returned>`.
    func testADocumentIsUploadedThenReferenced() async throws {
        let app = try await launchSignedIn(seed: "pdf:1048576:name=secret-XYZ.pdf")
        defer { app.terminate() }
        try pick(app, "obsidian")
        element(app, "share-send").tap()
        let awaited11 = try await lastResult(app)
        XCTAssertEqual(awaited11, "sent:obsidian")
        let state = try await gatewayState()
        XCTAssertEqual(counter(state, "share_uploads"), 1)
        XCTAssertEqual(counter(state, "upload_bytes"), 1048576, "every byte arrived")
        let paths = Array((state["uploads"] as? [String: Any] ?? [:]).keys)
        XCTAssertEqual(paths.count, 1)
        XCTAssertTrue(paths.first?.hasSuffix("/secret-XYZ.pdf") == true, "the filename kept: \(paths)")
        let message = ((state["posts"] as? [[String: Any]])?.first?["message"] as? String) ?? ""
        XCTAssertEqual(message, "[attached_file 1] \(paths.first ?? "?")", "the token and the path, as returned")
        XCTAssertEqual(violations(state), 0)
        XCTAssertEqual(inboxCount(app), 0)
    }

    /// 50 MB, the gateway's limit, through the page in 4 MiB chunks: byte for
    /// byte, and WebKit's content process survives it.
    func testFiftyMegabytesGoThroughByteForByte() async throws {
        let app = try await launchSignedIn(seed: "pdf:52428800")
        defer { app.terminate() }
        try pick(app, "obsidian")
        let start = Date()
        element(app, "share-send").tap()
        let awaited12 = try await lastResult(app, timeout: 180)
        XCTAssertEqual(awaited12, "sent:obsidian")
        print("F3: a 50 MB share took \(Int(Date().timeIntervalSince(start))) s from Send to confirmed")
        let awaited13 = try await gatewayState()
        XCTAssertEqual(counter(awaited13, "upload_bytes"), 52428800)
        XCTAssertEqual(element(app, "share-terminations").label, "0", "no web content process died")
    }

    /// Over 50 MB is refused at capture, nothing staged; a gateway's 413 is
    /// shown in its own words.
    func testOverTheLimitIsRefusedAtCaptureAndA413IsShown() async throws {
        var app = try await launchSignedIn(seed: "pdf:52428801")
        XCTAssertEqual(inboxCount(app), 0, "refused at capture: nothing in the inbox")
        XCTAssertFalse(element(app, "share-picker").exists)
        app.terminate()

        _ = try await Self.post("\(Self.gatewayControl)/__upload-limit?bytes=1048576")
        app = try await launchSignedIn(seed: "pdf:2097152")
        defer { app.terminate() }
        try pick(app, "obsidian")
        element(app, "share-send").tap()
        let result = element(app, "share-result")
        XCTAssertTrue(result.waitForExistence(timeout: 60))
        XCTAssertEqual(result.label, "failed:File too large (max 1MB)")
        let awaited14 = try await gatewayState()
        XCTAssertEqual(counter(awaited14, "share_posts"), 0)
    }

    func testAnUnsupportedTypeShowsTheGatewaysWords() async throws {
        let app = try await launchSignedIn(seed: "bin:1024")
        defer { app.terminate() }
        try pick(app, "obsidian")
        element(app, "share-send").tap()
        let result = element(app, "share-result")
        XCTAssertTrue(result.waitForExistence(timeout: 30))
        XCTAssertEqual(result.label, "failed:Unsupported file type: .bin")
        let awaited15 = try await gatewayState()
        XCTAssertEqual(counter(awaited15, "share_posts"), 0)
    }

    // MARK: - Failure and cleanup

    /// The gateway is unreachable at Send: the share fails as unreachable and
    /// is kept; Retry sends it once the gateway is back.
    func testUnreachableIsKeptAndRetried() async throws {
        let app = try await launchSignedIn()
        defer { app.terminate() }
        share(app, "latchkey://share?url=https://example.com/u")
        try pick(app, "obsidian")
        _ = try await Self.post("\(Self.gatewayControl)/__restart?down=8")
        _ = try await Self.post("\(Self.proxyControl)/mode?blackhole=1")
        element(app, "share-send").tap()
        let result = element(app, "share-result")
        XCTAssertTrue(result.waitForExistence(timeout: 40))
        XCTAssertEqual(result.label, "failed:unreachable")
        XCTAssertEqual(element(app, "share-sheet-inbox-count").label, "1", "a failed share is kept")
        let awaited16 = try await gatewayState()
        XCTAssertEqual(counter(awaited16, "share_posts"), 0)
        _ = try await Self.post("\(Self.proxyControl)/mode?blackhole=0")
        try await Task.sleep(for: .seconds(9))
        element(app, "share-retry").tap()
        let awaited17 = try await lastResult(app, timeout: 45)
        XCTAssertEqual(awaited17, "sent:obsidian")
        let awaited18 = try await gatewayState()
        XCTAssertEqual(counter(awaited18, "share_posts"), 1)
        XCTAssertEqual(inboxCount(app), 0)
    }

    /// Later while the post is in flight (issue #1): the gateway already has
    /// the message, so its answer is recorded after the sheet has gone and
    /// the item is never offered again -- a second Send would post it twice.
    func testLaterAfterThePostLeftIsRecordedNotReoffered() async throws {
        let app = try await launchSignedIn()
        defer { app.terminate() }
        share(app, "latchkey://share?url=https://example.com/later-post")
        try pick(app, "obsidian")
        _ = try await Self.post("\(Self.gatewayControl)/__slow?post=5")
        element(app, "share-send").tap()
        var posts: [[String: Any]] = []
        for _ in 0..<60 where posts.isEmpty {
            try await Task.sleep(for: .milliseconds(250))
            posts = (try await gatewayState())["posts"] as? [[String: Any]] ?? []
        }
        XCTAssertEqual(posts.count, 1, "the gateway has the post before its answer")
        let later = element(app, "share-cancel")
        XCTAssertTrue(later.isHittable, "Later is offered while sending")
        later.tap()
        XCTAssertTrue(element(app, "share-picker").waitForNonExistence(timeout: 5), "Later closes the sheet")
        let awaited = try await lastResult(app, timeout: 20)
        XCTAssertEqual(awaited, "sent:obsidian", "the late answer is recorded")
        XCTAssertEqual(inboxCount(app), 0, "a delivered share leaves the inbox")

        XCUIDevice.shared.press(.home)
        try await Task.sleep(for: .seconds(2))
        app.activate()
        XCTAssertFalse(element(app, "share-picker").waitForExistence(timeout: 8),
                       "the next foreground does not offer it again")
        let state = try await gatewayState()
        XCTAssertEqual(counter(state, "share_posts"), 1)
        XCTAssertEqual(violations(state), 0)
    }

    /// Later before the post left: nothing is posted, the item stays, and the
    /// next foreground offers it again. Also the positive control for the
    /// test above: the same foreground does bring a kept item back.
    func testLaterBeforeThePostLeftKeepsTheItem() async throws {
        let app = try await launchSignedIn()
        defer { app.terminate() }
        share(app, "latchkey://share?url=https://example.com/later-verify")
        try pick(app, "obsidian")
        _ = try await Self.post("\(Self.gatewayControl)/__slow?slots=4")
        element(app, "share-send").tap()
        XCTAssertTrue(element(app, "share-progress").waitForExistence(timeout: 5), "the send has started")
        element(app, "share-cancel").tap()
        XCTAssertTrue(element(app, "share-picker").waitForNonExistence(timeout: 5), "Later closes the sheet")
        try await Task.sleep(for: .seconds(7))
        let before = try await gatewayState()
        XCTAssertEqual(counter(before, "share_posts"), 0, "nothing was posted after Later")
        XCTAssertEqual(inboxCount(app), 1, "the item stays")

        _ = try await Self.post("\(Self.gatewayControl)/__slow")
        XCUIDevice.shared.press(.home)
        try await Task.sleep(for: .seconds(2))
        app.activate()
        try pick(app, "obsidian")
        element(app, "share-send").tap()
        let awaited = try await lastResult(app)
        XCTAssertEqual(awaited, "sent:obsidian")
        let after = try await gatewayState()
        XCTAssertEqual(counter(after, "share_posts"), 1, "posted once, on the second Send")
    }

    /// Items older than 7 days go at launch, unsent.
    func testTheSweepRunsAtLaunch() async throws {
        let app = try await launchSignedIn(seed: "pdf:1024:age=8d")
        defer { app.terminate() }
        XCTAssertEqual(inboxCount(app), 0, "the 8-day item was swept")
        XCTAssertFalse(element(app, "share-picker").exists)
    }

    /// The positive control for the sweep and capture tests: a fresh seed IS
    /// in the inbox, and the instrument reads it.
    func testAFreshSeedIsInTheInbox() async throws {
        let app = try await launchSignedIn(seed: "pdf:1024:age=6d")
        defer { app.terminate() }
        XCTAssertTrue(element(app, "share-session-obsidian").waitForExistence(timeout: 30), "the picker comes up")
        element(app, "share-cancel").tap()
        XCTAssertEqual(inboxCount(app), 1, "a 6-day item stays, and the instrument sees it")
    }

    // MARK: - Stage 2: the share sheet's app row

    /// F3 §7, "The share sheet route (stage 2)" -- fragile by nature: it
    /// drives Safari and the system share sheet, whose layout is Apple's.
    /// A page is shared from Safari to "Latchkey"; the extension saves it to
    /// the App Group inbox and sends nothing; the app, brought back, has the
    /// item from `source: extension` and delivers it like any other.
    func testTheShareSheetSavesForTheAppAndTheAppSendsIt() async throws {
        let app = try await launchSignedIn()
        defer { app.terminate() }
        let page = "\(Self.gatewayControl)/ext-share-probe"
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        safari.launch()
        XCUIDevice.shared.system.open(URL(string: page)!)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if springboard.buttons["Open"].waitForExistence(timeout: 2) { springboard.buttons["Open"].tap() }
        XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 15), "Safari is in front")
        try await Task.sleep(for: .seconds(2))

        // Share: a toolbar button on older layouts; on iOS 26 it is in the
        // page menu, the leading button of the address bar.
        let share = safari.buttons.matching(NSPredicate(format: "identifier == 'ShareButton' OR label == 'Share'")).firstMatch
        if !share.waitForExistence(timeout: 3) {
            let menu = safari.buttons.matching(NSPredicate(
                format: "identifier CONTAINS[c] 'PageMenu' OR identifier CONTAINS[c] 'PageFormat' OR label CONTAINS[c] 'Page Menu' OR label == 'More'")).firstMatch
            XCTAssertTrue(menu.waitForExistence(timeout: 5),
                          "Safari's page menu; its buttons: \(safari.buttons.allElementsBoundByIndex.prefix(30).map { "\($0.identifier)|\($0.label)" })")
            menu.tap()
        }
        XCTAssertTrue(share.waitForExistence(timeout: 5),
                      "Safari offers Share; on screen: \(safari.buttons.allElementsBoundByIndex.prefix(40).map { "\($0.identifier)|\($0.label)" })")
        share.tap()

        // The app row. New extensions may sit behind "More" at its end.
        let row = safari.descendants(matching: .any).matching(NSPredicate(format: "label == 'Latchkey'")).firstMatch
        if !row.waitForExistence(timeout: 8) {
            let moreApps = safari.descendants(matching: .any).matching(NSPredicate(format: "label == 'More'")).firstMatch
            if moreApps.exists { moreApps.tap() }
        }
        XCTAssertTrue(row.waitForExistence(timeout: 8), "Latchkey is in the share sheet's app row (the extension is built in)")
        row.tap()

        let save = safari.descendants(matching: .any)["share-capture-save"]
        XCTAssertTrue(save.waitForExistence(timeout: 15), "the extension's sheet offers Save for Latchkey")
        save.tap()
        let saved = safari.descendants(matching: .any)["share-capture-saved"]
        let savedLabel = snapshotLabel(saved, within: 10)
        XCTAssertNotNil(savedLabel, "it says Saved. Open Latchkey to send it.")
        XCTAssertTrue(savedLabel?.contains("Open Latchkey") == true, savedLabel ?? "<never shown>")
        let before = try await gatewayState()
        XCTAssertEqual(counter(before, "share_posts"), 0, "the extension sent nothing")
        _ = saved.waitForNonExistence(timeout: 5)

        app.activate()
        let source = element(app, "share-item-source")
        XCTAssertTrue(source.waitForExistence(timeout: 30), "the app brings the saved share up")
        XCTAssertEqual(source.label, "extension", "written by the extension, to the group inbox")
        try pick(app, "obsidian")
        element(app, "share-send").tap()
        let awaitedExt = try await lastResult(app)
        XCTAssertEqual(awaitedExt, "sent:obsidian")
        let state = try await gatewayState()
        let message = ((state["posts"] as? [[String: Any]])?.first?["message"] as? String) ?? ""
        XCTAssertTrue(message.contains(page), "the post carries the shared URL: \(message)")
        XCTAssertEqual(violations(state), 0)
    }

    // MARK: - Helpers

    private func launch(seed: String? = nil, reset: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = (reset ? ["-UITestResetWorkspaces", "-UITestResetShare"] : []) + [
            "-UITestHomePage", Self.gateway,
            "-TestStatusFixture", OfflineHarnessTests.fixture(suffix: "tail-scale.ts.net", peers: ["gw"]),
            "-TestProxyEndpoint", OfflineHarnessTests.proxyEndpoint,
            "-TestProxyCredential", OfflineHarnessTests.proxyCredential,
            "-UITestKeepWebData",
        ] + (seed.map { ["-UITestSeedShare", $0] } ?? [])
        app.launch()
        return app
    }

    private func launchSignedIn(seed: String? = nil) async throws -> XCUIApplication {
        let app = launch(seed: seed)
        XCTAssertTrue(element(app, "token-sheet").waitForExistence(timeout: 30), "signed out at first")
        try await signIn(app)
        return app
    }

    /// Opens a share URL as another app would. The system may ask first.
    private func share(_ app: XCUIApplication, _ url: String) {
        XCUIDevice.shared.system.open(URL(string: url)!)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let open = springboard.buttons["Open"]
        if open.waitForExistence(timeout: 3) { open.tap() }
    }

    /// Waits for the picker's list, then picks `key`.
    private func pick(_ app: XCUIApplication, _ key: String,
                      file: StaticString = #filePath, line: UInt = #line) throws {
        let row = element(app, "share-session-\(key)")
        XCTAssertTrue(row.waitForExistence(timeout: 30), "the picker lists \(key)", file: file, line: line)
        // The picker is a sheet; its rows are in the tree from its first frame.
        row.tapWhenSettled(in: app, file: file, line: line)
        XCTAssertEqual(element(app, "share-destination-selected").label, key, file: file, line: line)
    }

    /// The outcome of the share just sent: the sheet's result while it is up,
    /// else the counted instrument once the sheet has gone.
    private func lastResult(_ app: XCUIApplication, timeout: Double = 40) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        let before = (try? element(app, "share-last-result").snapshot())?.label ?? "none"
        while Date() < deadline {
            if let r = try? element(app, "share-result").snapshot(), !r.label.isEmpty { return r.label }
            if !element(app, "share-picker").exists, let last = try? element(app, "share-last-result").snapshot(),
               last.label != "none", last.label != before {
                return last.label
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        return "no result within \(Int(timeout)) s"
    }

    /// The inbox count, read with no sheet up (a sheet hides what is under it).
    private func inboxCount(_ app: XCUIApplication) -> Int {
        // After a sent or queued result the sheet closes itself 2 s later
        // (ShareDelivery.finish). A Cancel tap aimed at it then can find it in
        // the tree and gone by the tap, which fails the test (seen under the
        // load of eight shards, F14): wait that close out instead, and let
        // presentations settle before looking.
        if let r = try? element(app, "share-result").snapshot(),
           r.label.hasPrefix("sent:") || r.label.hasPrefix("queued:") {
            _ = element(app, "share-picker").disappears(within: 10)
        }
        _ = app.settles(within: 10)
        if element(app, "share-picker").exists, element(app, "share-cancel").exists {
            element(app, "share-cancel").tap()
        }
        _ = element(app, "share-picker").waitForNonExistence(timeout: 5)
        let marker = element(app, "share-inbox-count")
        guard marker.waitForExistence(timeout: 5) else { return -1 }
        return Int(marker.label) ?? -1
    }

    private func signIn(_ app: XCUIApplication) async throws {
        let minted = try JSONSerialization.jsonObject(
            with: try await Self.post("\(Self.gatewayControl)/__mint?kind=cli")) as? [String: Any]
        let url = try XCTUnwrap(minted?["url"] as? String)
        UIPasteboard.general.string = url
        let paste = element(app, "token-paste-button").exists
            ? element(app, "token-paste-button")
            : app.buttons["Paste"].firstMatch
        XCTAssertTrue(paste.waitForExistence(timeout: 10), "the sheet offers Paste")
        // Callers come here as soon as the sheet exists, i.e. mid-slide.
        paste.tapWhenSettled(in: app)
        XCTAssertTrue(element(app, "token-sheet").waitForNonExistence(timeout: 30), "signed in")
    }

    /// The element's label from one snapshot, taken as soon as it exists;
    /// nil if it never did. `exists` and then `.label` are two queries, and
    /// a sheet that dismisses itself between them fails the test on the
    /// second; `snapshot()` throws instead (F14: seen under shard load).
    private func snapshotLabel(_ e: XCUIElement, within timeout: TimeInterval) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let s = try? e.snapshot() { return s.label }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        return nil
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func gatewayState() async throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: try await Self.get("\(Self.gatewayControl)/__state")) as? [String: Any] ?? [:]
    }

    private func counter(_ state: [String: Any], _ name: String,
                         file: StaticString = #filePath, line: UInt = #line) -> Int {
        let counters = state["counters"] as? [String: Any] ?? [:]
        guard let value = counters[name] as? Int else {
            XCTFail("the fake gateway reports no counter named \(name)", file: file, line: line)
            return 0
        }
        return value
    }

    private func violations(_ state: [String: Any]) -> Int {
        (state["violations"] as? [Any])?.count ?? -1
    }

    private static func get(_ url: String) async throws -> Data {
        var request = URLRequest(url: URL(string: url)!, timeoutInterval: 5)
        request.httpMethod = "GET"
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    @discardableResult
    private static func post(_ url: String) async throws -> Data {
        var request = URLRequest(url: URL(string: url)!, timeoutInterval: 5)
        request.httpMethod = "POST"
        let (data, _) = try await URLSession.shared.data(for: request)
        return data
    }
}
