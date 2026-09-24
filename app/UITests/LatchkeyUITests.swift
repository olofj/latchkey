// Copyright (c) Tailscale Inc & contributors
// SPDX-License-Identifier: BSD-3-Clause

//
//  LatchkeyUITests.swift
//  LatchkeyUITests
//
//  UI tests for Latchkey.
//
//  Until the tailnet first reaches `Running` the app shows a
//  ConnectionGateView (brand header + "Tailscale Status" + Login); once
//  connected it shows the dashboard: one full-screen web view. So:
//
//  - Connection-independent tests (brand header, status, Settings, gateway
//    persistence) run against the gate and stay green on any sim.
//  - Harness tests (-UITestProxyBounceHarness) drive a real WKWebView against
//    an in-app URL scheme handler: connection bounce, web content process
//    recovery (R7), window.open handling (R3). Also hermetic.
//  - Connected tests (gateway load, lifecycle, login) need a working tailnet.
//    They authenticate non-interactively via an auth key when one is staged
//    (see `resolvedTestAuthKey`), and otherwise they FAIL (never skip) — a
//    broken connection must be a loud failure, not a silent green. Stage a
//    key at ~/.aperture-ios-authkey (or pass AUTHKEY=... / set
//    APERTURE_TEST_AUTHKEY). Milestones M2 and M3 replace this dependency.
//
//  Run from the command line:
//
//    make test                                # stages ~/.aperture-ios-authkey if present
//    make test AUTHKEY=tskey-auth-...         # explicit key
//    scripts/run-uitests.sh
//    xcodebuild test -project Latchkey.xcodeproj -scheme Latchkey \
//      -configuration Debug \
//      -destination 'platform=iOS Simulator,name=iPhone 17' \
//      -derivedDataPath build/DerivedData
//

import XCTest

@MainActor
final class LatchkeyUITests: XCTestCase {

    // MARK: - Fixtures

    /// The gateway these tailnet-dependent tests load. Since M5 the app has
    /// no default gateway (the picker chooses one), so `launchConnected` sets
    /// it explicitly with `-UITestHomePage`.
    ///
    /// **From the environment, never hardcoded.** This used to name the
    /// author's own gateway on his own tailnet, which was wrong twice over: a
    /// real tailnet name in a test is how a leak turns into a pass (R10), and
    /// nobody else's checkout could run these tests at all. Set
    /// `LATCHKEY_TEST_GATEWAY` to a full `https://` URL for a gateway on the
    /// tailnet the simulator's node joins.
    static var defaultGatewayURL: String {
        ProcessInfo.processInfo.environment["LATCHKEY_TEST_GATEWAY"] ?? ""
    }

    /// A substring of `defaultGatewayURL`'s host, used to recognise the loaded
    /// page by its URL: the first label of the host, e.g. `gateway` from
    /// `gateway.<tailnet>.ts.net`. Upstream matched on "ai", the short name of
    /// its chat peer.
    static var defaultGatewayHostFragment: String {
        URL(string: defaultGatewayURL)?.host()?
            .split(separator: ".").first.map(String.init) ?? ""
    }

    override func setUpWithError() throws {
        // Stop on the first failure so we get a clean signal.
        continueAfterFailure = false
    }

    // XCTest's setUp/tearDown overrides stay nonisolated, so we can't touch
    // @MainActor XCUITest APIs there. The test methods below are @MainActor
    // (via the class), so call `attachScreenshot(_:)` from inside a test when
    // you want a snapshot.

    // MARK: - Connection-independent tests (run on any sim)

    /// The app launches and shows its onboarding chrome (brand header +
    /// "Tailscale Status" section). Pre-connection this is the connection
    /// gate; the brand header is the sole "Aperture" branding (no nav-bar
    /// title), so we wait on its accessibility identifier.
    func testAppLaunchesAndShowsStatus() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestResetLogin"]
        app.launch()

        XCTAssertTrue(
            waitForBrandHeader(app, timeout: 20),
            "The Aperture brand header should appear on launch"
        )

        XCTAssertTrue(
            app.staticTexts["Tailscale Status"].waitForExistence(timeout: 10),
            "The Tailscale Status section header should always be visible"
        )
    }

    // MARK: - Interactive login / logout / relogin (null identity provider)

    /// Full interactive login → logout → relogin cycle, WITHOUT an auth key,
    /// authenticating as `testuser@nullid.fly.dev`.
    ///
    /// `testuser@nullid.fly.dev` is a Tailscale "null" OIDC identity provider:
    /// the Tailscale login page recognises the `nullid.fly.dev` domain and,
    /// after you submit the email, redirects to a one-page provider that just
    /// shows the parsed username (`testuser`) and a single "Log in" button —
    /// no password. Confirming there completes the OAuth callback and brings
    /// the tailnet up.
    ///
    /// Why this test exists: the connected tests all log in non-interactively
    /// with a staged auth key, so the real `StatusViewModel.showAuth()` /
    /// `ASWebAuthenticationSession` path, the Settings logout path, and the
    /// post-logout relogin (via the browser's `LoginBanner`) were never
    /// exercised by an automated test. This one drives the actual UI.
    ///
    /// XCUITest-vs-ASWebAuthenticationSession notes (learned the hard way):
    /// the auth sheet's web content is hosted in a *separate* (out-of-process)
    /// WebKit, so it is NOT in `app`'s element tree right away — there's a
    /// ~10–30s accessibility-bridging lag before `app.webViews.textFields` /
    /// `app.webViews.buttons` see it. The helpers below use generous timeouts
    /// for that reason. Once exposed, the email field is
    /// `app.webViews.textFields.firstMatch` and the submit buttons are
    /// `app.webViews.buttons["Sign in"]` (Tailscale page) and
    /// `app.webViews.buttons["Log in"]` (nullid confirm page).
    ///
    /// This is a CONNECTED test: it needs network reach to
    /// controlplane/login.tailscale.com + nullid.fly.dev (the sim shares the
    /// host network). It does NOT need an auth key — that's the whole point.
    func testInteractiveLoginLogoutRelogin() throws {
        let app = XCUIApplication()
        // Fresh: wipe any saved node creds so we start at the connection gate
        // (NeedsLogin). Crucially, do NOT stage an auth key — we want the
        // interactive web-auth path, not the headless key path.
        app.launchArguments = ["-UITestResetLogin"]
        app.launch()

        XCTAssertTrue(waitForBrandHeader(app, timeout: 20),
                      "Brand header should appear on launch")
        XCTAssertTrue(waitForGateLoginButton(app, timeout: 60),
                      "Node should reach NeedsLogin and show the Login button " +
                      "(requires network reach to controlplane.tailscale.com)")

        // --- Phase 1: interactive login ---
        app.buttons["login-button"].tap()
        XCTAssertTrue(completeNullIdLogin(app, emailFieldTimeout: 90),
                      "Interactive login via testuser@nullid.fly.dev should " +
                      "complete (email → Sign in → nullid Log in)")
        guard requireBrowserReady(app, timeout: 90) else { return }
        attachScreenshot(app, named: "login-success")

        // --- Phase 2: reset from Settings (R32: the one way to leave the
        // tailnet; the separate "Log out of Tailscale" was folded into it) ---
        XCTAssertTrue(openSettings(app), "Settings should open from the browser gear")
        let reset = settingsResetButton(in: app)
        scrollToElement(reset, in: app)
        XCTAssertTrue(reset.waitForExistence(timeout: 10),
                      "The (red) Reset app button should be present on Settings")
        reset.tap()

        // SwiftUI confirmation alert (R32): title "Reset Latchkey?",
        // destructive confirm "Reset".
        let alertConfirm = app.alerts["Reset Latchkey?"].buttons["Reset"]
        XCTAssertTrue(alertConfirm.waitForExistence(timeout: 10),
                      "Reset confirmation alert should appear")
        alertConfirm.tap()

        // A reset signs out of the dashboard, expires the node's key at the
        // control plane (R32; control is reachable here, so no "couldn't
        // reach Tailscale" alert), then deletes the whole (and currently
        // only) session, and the workspace manager seeds a fresh one. That
        // replacement reaches NeedsLogin and normally renders the connection
        // gate. Accept the browser LoginBanner too in case the UI transition
        // overlaps polling.
        let needsLoginAgain = waitForNeedsLoginAgain(app, timeout: 60)
        if !needsLoginAgain { attachScreenshot(app, named: "logout-no-needslogin") }
        XCTAssertTrue(needsLoginAgain,
                      "After logout the app should need login again — either the " +
                      "browser's LoginBanner (login-banner-button) or the " +
                      "connection gate's login-button should be reachable")

        // --- Phase 3: relogin ---
        // Tap whichever NeedsLogin trigger is present, then drive the same
        // null-id auth flow. The banner button and the gate button both call
        // `StatusViewModel.showAuth()`.
        let banner = app.buttons["login-banner-button"]
        let gate = app.buttons["login-button"]
        let reloginTrigger = banner.exists ? banner : gate
        XCTAssertTrue(reloginTrigger.exists, "A relogin trigger should be present")
        reloginTrigger.tap()
        XCTAssertTrue(completeNullIdLogin(app, emailFieldTimeout: 90),
                      "Relogin via testuser@nullid.fly.dev should complete")

        // Relogin success = all NeedsLogin controls clearing. `needsAuth`
        // flips false when the replacement node leaves NeedsLogin
        // (Starting/Running), so their disappearance proves the callback
        // completed. Using this state signal also avoids mistaking browser
        // chrome appearing during startup for completed authentication.
        let bannerCleared = NSPredicate { obj, _ -> Bool in
            guard let app = obj as? XCUIApplication else { return false }
            return !app.buttons["login-banner-button"].exists
                && !app.buttons["login-button"].exists
        }
        let bannerExp = XCTNSPredicateExpectation(predicate: bannerCleared, object: app)
        let reloginDone = XCTWaiter().wait(for: [bannerExp], timeout: 90) == .completed
        if !reloginDone { attachScreenshot(app, named: "relogin-banner-stuck") }
        XCTAssertTrue(reloginDone,
                      "After relogin the LoginBanner should clear (needsAuth → " +
                      "false once the tailnet reaches Running). If it stays, the " +
                      "relogin callback did not complete.")
        // The state signal can clear just before SwiftUI swaps the connection
        // gate back to browser chrome. Wait for that presentation instead of
        // requiring the toolbar in the same accessibility snapshot.
        XCTAssertTrue(connectedBrowserMarker(app).waitForExistence(timeout: 15),
                      "The dashboard should appear after a successful relogin")
        attachScreenshot(app, named: "relogin-success")
    }

    /// Tapping the gear opens Settings; Done dismisses it. The gear lives in
    /// the connection gate (and in the browser once connected) — both carry
    /// the `settings-button` identifier, so this test is connection-independent.
    func testOpenAndCloseSettings() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestResetLogin"]
        app.launch()

        XCTAssertTrue(waitForBrandHeader(app, timeout: 20))

        let settingsButton = app.buttons["settings-button"]
        XCTAssertTrue(
            settingsButton.waitForExistence(timeout: 10),
            "Settings gear button should be reachable"
        )
        settingsButton.tap()

        // Settings is presented as a full-screen cover with its own nav bar.
        XCTAssertTrue(
            app.navigationBars["Settings"].waitForExistence(timeout: 10),
            "Settings screen should appear after tapping the gear"
        )
        // A connection-independent control that only lives on the Settings screen.
        let reset = settingsResetButton(in: app)
        scrollToElement(reset, in: app)
        XCTAssertTrue(
            reset.waitForExistence(timeout: 5),
            "Reset app button should be present on the Settings screen"
        )

        // Done dismisses the cover.
        let doneButton = app.buttons["settings-done-button"]
        XCTAssertTrue(doneButton.exists, "Done button should exist in Settings")
        doneButton.tap()

        // The gear becoming hittable again proves Settings dismissed and we're
        // back at the root (gate or browser — both have a `settings-button`).
        let backAtRoot = waitForHittable(app.buttons["settings-button"], timeout: 10)
        if !backAtRoot { attachScreenshot(app, named: "settings-not-dismissed") }
        XCTAssertTrue(backAtRoot,
                      "Should return to the root (settings gear hittable) after Done")
    }

    /// Editing the Home Page in Settings and then dismissing **without**
    /// pressing Return should still persist — the value must survive a fresh
    /// app launch, which re-seeds the field from UserDefaults (the on-disk
    /// source of truth).
    ///
    /// This catches the bug where the home page was only saved inside the
    /// TextField's `onSubmit` (the Return key). A user who typed a new URL and
    /// tapped Done (no Return) lost the change.
    ///
    /// Connection-independent: Settings is always reachable (from the gate's
    /// gear pre-connection, or the browser's gear post-connection).
    /// Hermetic: reads the original value, changes it, verifies, then restores.
    /// Settings refuses a gateway the tailnet does not carry, and says why.
    ///
    /// This test used to assert the opposite: that any URL typed here persisted
    /// across a relaunch. That behaviour was removed deliberately (`65543c4`,
    /// the M5 review's finding) — a gateway that is not on the tailnet would be
    /// loaded DIRECT, off the tailnet, and would then be the origin a pasted
    /// sign-in link is sent to. `commitGateway` now goes through the same gate
    /// as the picker's manual entry, and this suite is connection-independent,
    /// so there is no peer list to check a name against and every entry is
    /// refused pending one.
    ///
    /// A silent refusal would look like the field simply not working, so the
    /// reason must be on screen — that is the part worth pinning.
    ///
    /// The persistence property this test used to cover has not been dropped:
    /// `DiscoveryTests.testTheChosenGatewayPersistsAcrossRelaunch` covers it
    /// against a real tailnet, which is the only place it can now be true.
    func testSettingsRefusesAGatewayTheTailnetDoesNotCarry() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestResetHomePage", "-UITestResetLogin"]
        app.launch()

        XCTAssertTrue(waitForBrandHeader(app, timeout: 20))
        let settingsButton = app.buttons["settings-button"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 10),
                      "Settings gear should be reachable")
        settingsButton.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10),
                      "Settings screen should appear after tapping the gear")

        let field = app.textFields["home-page-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10),
                      "the gateway field should be present in Settings")
        let offTailnet = "https://\(String(UUID().uuidString.prefix(8)).lowercased()).example.test"
        field.clearAndType(text: offTailnet)
        XCTAssertEqual(field.value as? String, offTailnet, "typing should update the field")

        // Return commits it, which is where the gate runs. Typed into the FIELD,
        // not the app: `app.typeText` goes to whatever holds focus, which after
        // `clearAndType` is not reliably this field.
        field.typeText("\n")
        // `descendants(matching: .any)`, not `app.staticTexts[...]`: an
        // identifier on a Text inside a Form Section is not reliably surfaced as
        // a staticText, and the narrow query found nothing while the app's own
        // log showed the refusal had happened.
        // Settings is a half sheet and a Form builds its rows lazily, so the
        // Gateway section's rows leave the tree the moment the keyboard shifts
        // the scroll position — the first attempt at this test found neither the
        // error NOR the field it had just typed into. `reveal` scrolls it back.
        let error = app.descendants(matching: .any)
            .matching(identifier: "settings-gateway-error").firstMatch
        if !error.reveal(scrolling: app.collectionViews.firstMatch) {
            // Say what WAS on screen, so the next failure is diagnosable from
            // the log rather than needing another run.
            let ids = app.descendants(matching: .any).allElementsBoundByIndex
                .prefix(60).map(\.identifier).filter { !$0.isEmpty }
            XCTFail("a refused gateway must say so; a silent refusal reads as a "
                    + "broken field. Identifiers on screen: \(ids)")
        }
        XCTAssertFalse(error.label.isEmpty, "and the reason must be readable: \(error.label)")

        // And it is not kept. Dismiss, relaunch, look again: the field is back
        // to whatever the reset default is, never the off-tailnet host.
        app.buttons["settings-done-button"].tap()
        XCTAssertTrue(waitForHittable(app.buttons["settings-button"], timeout: 10),
                      "Should return to the root after Done")
        app.launchArguments = ["-UITestResetLogin"]   // do NOT reset: see what saved
        app.terminate()
        app.launch()
        XCTAssertTrue(waitForBrandHeader(app, timeout: 20), "App should relaunch")
        app.buttons["settings-button"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        let after = app.textFields["home-page-field"]
        XCTAssertTrue(after.waitForExistence(timeout: 10))
        let persisted = (after.value as? String) ?? ""
        XCTAssertFalse(persisted.contains("example.test"),
                       "a refused gateway must not be persisted; got '\(persisted)'")
    }

    // MARK: - Lifecycle / proxy-bounce integration tests

    // Hermetic; no tailnet required.

    /// A Running -> Starting -> Running status glitch must not recreate/reload
    /// the document, and a fetch already in flight must still complete. The
    /// app-hosted harness uses a real WKWebView + WKURLSchemeHandler, so this
    /// exercises BrowserViewModel's actual Combine/WebKit lifecycle without an
    /// auth key, control plane, or tailnet peer.
    func testConnectionBounceDoesNotReloadPageOrLoseFetch() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestProxyBounceHarness"]
        app.launch()

        // A WKScriptMessage bridge mirrors the page's load/fetch state into
        // native accessibility labels. This avoids depending on WebKit's
        // occasionally delayed DOM accessibility bridge while still using a
        // real page, JavaScript fetch, and BrowserViewModel.
        let loads = app.staticTexts["bounce-load-count"]
        let fetch = app.staticTexts["bounce-fetch-status"]
        let bounce = app.buttons["simulate-connection-bounce"]
        XCTAssertTrue(loads.waitForExistence(timeout: 15))
        XCTAssertTrue(fetch.waitForExistence(timeout: 15))
        XCTAssertTrue(bounce.waitForExistence(timeout: 5))
        let firstLoad = NSPredicate(format: "label == %@", "ONE LOAD")
        let loadExpectation = XCTNSPredicateExpectation(predicate: firstLoad, object: loads)
        XCTAssertEqual(XCTWaiter().wait(for: [loadExpectation], timeout: 10), .completed,
                       "The harness document should execute once")
        XCTAssertEqual(fetch.label, "FETCH PENDING")

        bounce.tap()
        XCTAssertTrue(app.staticTexts["bounce-connection-status"]
            .waitForExistence(timeout: 2))

        let completed = NSPredicate(format: "label == %@", "FETCH COMPLETE")
        let completion = XCTNSPredicateExpectation(predicate: completed, object: fetch)
        XCTAssertEqual(XCTWaiter().wait(for: [completion], timeout: 10), .completed,
                       "The fetch started before the status bounce should complete")
        let reconnected = NSPredicate(format: "label == %@", "Connected")
        let reconnectExpectation = XCTNSPredicateExpectation(
            predicate: reconnected,
            object: app.staticTexts["bounce-connection-status"])
        XCTAssertEqual(XCTWaiter().wait(for: [reconnectExpectation], timeout: 5), .completed)
        XCTAssertEqual(loads.label, "ONE LOAD",
                       "A connection-status bounce must not reload the document")
        XCTAssertFalse(app.descendants(matching: .any)
            .matching(identifier: "nav-error-overlay").firstMatch.exists)
        attachScreenshot(app, named: "proxy-bounce-no-reload-fetch-survived")
    }

    /// Used by `scripts/test-lock-resume.sh`, which sends this app process a
    /// host-side SIGSTOP after the Home transition and SIGCONT before activate.
    /// That freezes Swift, URLSession, Network.framework, and the embedded Go
    /// runtime together while retaining real scene background/active notifications.
    func testExternalProcessSuspendRecoversWithoutReloadingPage() throws {
        let app = XCUIApplication()
        launchConnected(app)
        guard requireBrowserReady(app) else { return }
        XCTAssertTrue(waitForPageLoaded(in: app, contains: Self.defaultGatewayHostFragment, timeout: 60))
        let address = app.buttons["url-pill"].label

        XCUIDevice.shared.press(.home)
        // The host helper sees the app's Background log, SIGSTOPs only the app
        // (the XCTest runner remains alive), waits >5s, then SIGCONTs it. Leave
        // enough wall time here for that cycle before asking SpringBoard to
        // activate the resumed app.
        Thread.sleep(forTimeInterval: 12)
        app.activate()

        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 7),
                      "The retained browser should remain available immediately after resume")
        let resumedAddress = app.buttons["url-pill"].label
        XCTAssertTrue(resumedAddress == address || resumedAddress.hasSuffix(".ts.net"),
                      "Resume must preserve the page; a bare MagicDNS name may canonicalize to its FQDN")
        XCTAssertFalse(app.descendants(matching: .any)
            .matching(identifier: "nav-error-overlay").firstMatch.exists)
    }

    /// Reproduces iOS socket defuncting without relying on simulator lock
    /// semantics: libtailscale calls shutdown(SHUT_RDWR) on every process TCP
    /// socket (without close/fd-reuse risk). A fresh tailnet load must recover
    /// reactively, with no scene background/foreground event to trigger it.
    func testTCPShutdownChaosRecoversFreshTailnetLoad() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestDefunctLoopback"]
        launchConnected(app)
        guard requireBrowserReady(app) else { return }
        XCTAssertTrue(waitForPageLoaded(in: app, contains: Self.defaultGatewayHostFragment, timeout: 60))

        let chaos = app.staticTexts["tcp-chaos-test-status"]
        XCTAssertTrue(chaos.waitForExistence(timeout: 15),
                      "TCP chaos hook should run after the node reaches Running")
        let damaged = XCTNSPredicateExpectation(
            predicate: NSPredicate { object, _ in
                guard let element = object as? XCUIElement else { return false }
                return element.label == "damaged" || element.label == "recovered"
            }, object: chaos)
        XCTAssertEqual(XCTWaiter().wait(for: [damaged], timeout: 20), .completed)

        reloadPage(app)

        let recovered = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "recovered"), object: chaos)
        XCTAssertEqual(XCTWaiter().wait(for: [recovered], timeout: 45), .completed,
                       "A LocalAPI -1004 should replace the loopback listener reactively")
        XCTAssertTrue(waitForPageLoaded(in: app, contains: Self.defaultGatewayHostFragment, timeout: 45),
                      "A fresh tailnet load should recover after all TCP sockets are shut down")
        XCTAssertFalse(app.descendants(matching: .any)
            .matching(identifier: "nav-error-overlay").firstMatch.exists)
    }

    /// A request opened after foreground must use the newly-published local
    /// SOCKS listener. Existing page preservation alone does not exercise that
    /// endpoint: its already-open relay could survive even when the listener
    /// used for new connections was defuncted by iOS.
    func testBackgroundResumeAllowsFreshTailnetLoad() throws {
        let app = XCUIApplication()
        launchConnected(app)
        guard requireBrowserReady(app) else { return }
        XCTAssertTrue(waitForPageLoaded(in: app, contains: Self.defaultGatewayHostFragment, timeout: 60))

        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 5)
        app.activate()

        reloadPage(app)

        XCTAssertTrue(waitForPageLoaded(in: app, contains: Self.defaultGatewayHostFragment, timeout: 30),
                      "A fresh tailnet load should reach the replacement SOCKS listener")
        XCTAssertFalse(app.descendants(matching: .any)
            .matching(identifier: "nav-error-overlay").firstMatch.exists)
    }

    /// Connected background/foreground regression. The simulator does not
    /// truly suspend processes when its display is powered off, so this drives
    /// scene lifecycle with XCUIDevice.home + app.activate and verifies that
    /// Aperture leaves the retained page alone.
    func testBackgroundResumeReconnectsWithoutReloadingPage() throws {
        let app = XCUIApplication()
        launchConnected(app)
        guard requireBrowserReady(app) else { return }
        XCTAssertTrue(waitForPageLoaded(in: app, contains: Self.defaultGatewayHostFragment, timeout: 60))

        let webView = app.webViews.firstMatch
        XCTAssertTrue(webView.waitForExistence(timeout: 10))
        let address = app.buttons["url-pill"].label

        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 5)
        app.activate()

        let resumedAddress = app.buttons["url-pill"].label
        XCTAssertTrue(resumedAddress == address || resumedAddress.hasSuffix(".ts.net"),
                      "Background/foreground must preserve the page; a bare MagicDNS name may canonicalize to its FQDN")
        XCTAssertTrue(webView.exists)
        XCTAssertFalse(app.descendants(matching: .any)
            .matching(identifier: "nav-error-overlay").firstMatch.exists)
    }

    // MARK: - Connected tests (require a logged-in sim; auth key automates it)

    /// The dashboard is up when `DashboardRootView`'s connected-browser
    /// marker exists. Upstream waited on the toolbar's More button; that
    /// toolbar is gone (PLAN §1.5) and the marker is the direct signal.
    @discardableResult
    private func waitForBrowserReady(_ app: XCUIApplication, timeout: TimeInterval = 90) -> Bool {
        connectedBrowserMarker(app).waitForExistence(timeout: timeout)
    }

    /// Launches the app, forwarding a staged auth key if one is available so a
    /// fresh (not-logged-in) sim can connect non-interactively.
    private func launchConnected(_ app: XCUIApplication) {
        if let key = Self.resolvedTestAuthKey() {
            app.launchEnvironment["APERTURE_AUTHKEY"] = key
            app.launchEnvironment["APERTURE_EPHEMERAL"] = Self.resolvedTestEphemeral()
        }
        // Reset both the configured home page and restored tab session so
        // connected tests are hermetic. The two are deliberately independent
        // in production: resetting only HomePage does not rewrite a persisted
        // current tab left by an earlier bad-URL test.
        // No tab reset needed: nothing about the page is restored (R2).
        // -UITestHomePage wins over the reset (it is applied after it): the
        // app has no default gateway since M5.
        // No gateway configured: fail loudly rather than launch at "" and time
        // out 60 s later against a blank page, which is the same doctrine as
        // the auth key below — a missing prerequisite must name itself.
        guard !Self.defaultGatewayURL.isEmpty else {
            XCTFail("""
                These tests need a gateway on the tailnet the node joins. Set \
                LATCHKEY_TEST_GATEWAY to its https:// URL, e.g. \
                LATCHKEY_TEST_GATEWAY=https://gateway.<tailnet>.ts.net.
                """)
            return
        }
        app.launchArguments += ["-UITestResetHomePage", "-UITestHomePage", Self.defaultGatewayURL]
        app.launch()
    }

    /// Waits for the connected browser to appear and FAILS (never skips) if it
    /// doesn't. Connected tests require a working tailnet connection — a broken
    /// connection must be a loud failure, never a silent skip. The connection
    /// is automated by staging an auth key (see `launchConnected` /
    /// `resolvedTestAuthKey`); without one, a fresh sim won't connect and this
    /// fails after the timeout.
    @discardableResult
    private func requireBrowserReady(_ app: XCUIApplication, timeout: TimeInterval = 90) -> Bool {
        guard waitForBrowserReady(app, timeout: timeout) else {
            attachScreenshot(app, named: "not-connected")
            XCTFail(
                "Tailnet did not reach Running state within \(Int(timeout))s — the " +
                "browser chrome never appeared. Connected tests require a connection. " +
                "Stage an auth key at ~/.aperture-ios-authkey (or pass AUTHKEY=... / " +
                "set APERTURE_TEST_AUTHKEY); on a not-logged-in sim without a key the " +
                "node can't authenticate. This is a hard failure by design — connected " +
                "tests never skip, so a broken connection is never silent.")
            return false
        }
        return true
    }

    /// With the tailnet connected, the first tab (always an Aperture chat = the
    /// home page) loads automatically in the browser — no bookmark to tap. We
    /// wait for the WKWebView and confirm the home page URL appears in the
    /// browser's URL field.
    func testHomePageLoadsWhenConnected() throws {
        let app = XCUIApplication()
        launchConnected(app)

        guard requireBrowserReady(app) else { return }

        // The browser view hosts a WKWebView (the current tab's page). Wait for it.
        let webView = app.webViews.firstMatch
        guard webView.waitForExistence(timeout: 30) else {
            attachScreenshot(app, named: "no-webview")
            XCTFail("Browser view / WKWebView did not appear once connected")
            return
        }

        // Confirm the home page URL was reached AND no navigation error
        // surfaced. We check the URL pill/host (the navigation reached the
        // server) rather than specific page content. The thing we must catch
        // is a *navigation failure* (cert/connectivity/proxy), which surfaces
        // the `nav-error-overlay`. So: reach the URL, then assert the error
        // overlay did NOT appear. (A 404 would be a *successful* load from
        // WebKit's view — but the 404 flakiness was a test-isolation bug, now
        // fixed: see testSettingsRefusesAGatewayTheTailnetDoesNotCarry.)
        let reached = waitForPageLoaded(in: app, contains: Self.defaultGatewayHostFragment, timeout: 60)
        attachScreenshot(app, named: reached ? "page-loaded" : "page-load-failed")
        XCTAssertTrue(reached,
                      "Gateway (\(Self.defaultGatewayURL)) was not reached within 60s. " +
                      "Check libtailscale logs: xcrun simctl spawn booted log stream " +
                      "--predicate 'subsystem == \"net.lixom.latchkey\"'")
        let errorOverlay = app.descendants(matching: .any)
            .matching(identifier: "nav-error-overlay").firstMatch
        // A navigation failure (e.g. the TLS cert trust failure this fixes)
        // surfaces the overlay quickly; give it a moment, then require absence.
        let overlayAppeared = errorOverlay.waitForExistence(timeout: 5)
        if overlayAppeared { attachScreenshot(app, named: "homepage-nav-error") }
        XCTAssertFalse(overlayAppeared,
                       "Home page load failed with a navigation error (cert/connectivity). " +
                       "The error overlay should not appear for a successful load.")
    }


    /// Returns true if `rect` overlaps the visible screen bounds (not fully off
    /// any edge). Used to catch the URL bar being floated off-screen or parked
    /// under the keyboard. Allows a little slop for the home-indicator area.
    private func frameIsOnScreen(_ rect: CGRect, screen: CGRect) -> Bool {
        let slop: CGFloat = 2
        return rect.minX < screen.maxX - slop
            && rect.maxX > screen.minX + slop
            && rect.minY < screen.maxY - slop
            && rect.maxY > screen.minY + slop
            && rect.width > 0 && rect.height > 0
    }

    /// Waits for the keyboard to dismiss. Returns true if it went away in time.
    @discardableResult
    private func waitForKeyboardDismissed(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let pred = NSPredicate { _, _ in !app.keyboards.firstMatch.exists }
        let exp = XCTNSPredicateExpectation(predicate: pred, object: nil)
        return XCTWaiter().wait(for: [exp], timeout: timeout) == .completed
    }

    /// Blurs a focused web input to dismiss its keyboard. Web inputs have no
    /// native "Done" accessory bar, so this tries (in order) the keyboard's
    /// HideKeyboard button, tapping a blank area of the page ABOVE the input,
    /// and the strip between the floated URL pill and the keyboard. It avoids
    /// tapping the floated URL pill itself (which would switch focus to the
    /// native URL field, not blur). Idempotent; the caller verifies the keyboard
    /// actually dismissed.
    private func blurWebInput(in app: XCUIApplication, screen: CGRect) {
        // Diagnostics: enumerate the keyboard's buttons so we can find the hide
        // key by its real identifier (it varies by iOS / locale).
        let kbButtons = app.keyboards.firstMatch.buttons.allElementsBoundByIndex
            .map { "\($0.identifier)=\($0.label)@\($0.frame)" }
        print("CYCLE: keyboard buttons = \(kbButtons)")

        // 1) The software keyboard's hide button (bottom-right keyboard icon).
        //    Try the common identifiers.
        for id in ["HideKeyboard", "hide keyboard", "Hide Keyboard", "DismissKeyboard"] {
            let b = app.keyboards.buttons[id]
            if b.waitForExistence(timeout: 1) {
                print("CYCLE: blur via keyboard button '\(id)' @ \(b.frame)")
                b.tap()
                return
            }
        }

        // 2) Tap a blank area ABOVE the chat input (the hero/header region on
        //    the home page). The home input sits ~y=267, so y≈120 is safely
        //    above it and below the notch. Tapping non-focusable page content
        //    blurs the focused textarea.
        let wf = app.webViews.firstMatch.frame
        let above = CGVector(dx: wf.midX, dy: wf.minY + 120)
        print("CYCLE: blur via above-input tap @ \(above)")
        app.coordinate(withNormalizedOffset: .zero).withOffset(above).tap()
        _ = XCTWaiter().wait(for: [XCTestExpectation()], timeout: 0.8)
        if !app.keyboards.firstMatch.exists { return }

        // 3) Tap the strip between the floated URL pill (~y=434..465) and the
        //    keyboard (~y=583), i.e. y≈500 — page content, not the pill.
        let strip = CGVector(dx: wf.midX, dy: 500)
        print("CYCLE: blur via strip tap @ \(strip)")
        app.coordinate(withNormalizedOffset: .zero).withOffset(strip).tap()
        _ = XCTWaiter().wait(for: [XCTestExpectation()], timeout: 0.8)
        if !app.keyboards.firstMatch.exists { return }

        // 4) Last resort: tap the very top of the webview.
        let top = CGVector(dx: wf.midX, dy: wf.minY + 40)
        print("CYCLE: blur via top tap @ \(top)")
        app.coordinate(withNormalizedOffset: .zero).withOffset(top).tap()
    }

    /// Polls `findChatInput` until it returns a hittable element or `totalTimeout`
    /// elapses. The webview a11y bridge is inconsistently slow to surface the
    /// chat textarea (sometimes tens of seconds), so a single call can miss it.
    private func retryFindChatInput(in app: XCUIApplication, totalTimeout: TimeInterval) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(totalTimeout)
        while Date() < deadline {
            if let i = findChatInput(in: app, timeout: 20), i.isHittable { return i }
            _ = XCTWaiter().wait(for: [XCTestExpectation()], timeout: 1.0)
        }
        return nil
    }

    /// Writes `app`'s screenshot to `path` as PNG so a non-vision agent can
    /// inspect it directly (XCTAttachments stay buried in the .xcresult bundle).
    private func saveScreenshot(_ app: XCUIApplication, to path: String) {
        let png = app.screenshot().pngRepresentation
        try? png.write(to: URL(fileURLWithPath: path))
        print("REPRO: wrote screenshot → \(path)")
    }

    /// Finds the Aperture chat input inside the webview. The chat UI's input has
    /// placeholder "Ask anything…" and is rendered as a `<textarea>` (maps to a
    /// web `textField`); fall back to a `textView` / `otherElement` with the
    /// placeholder text in case the element type changes. Returns nil if none
    /// is hittable within the timeout.
    private func findChatInput(in app: XCUIApplication, timeout: TimeInterval = 30) -> XCUIElement? {
        let webView = app.webViews.firstMatch
        guard webView.waitForExistence(timeout: timeout) else { return nil }

        // Primary: a web text field carrying the "Ask anything" placeholder.
        // The chat input's a11y label is "Message input" (an aria-label); its
        // placeholder is "Ask anything…" on the home page and "Reply…" on a
        // conversation. The webview a11y bridge is inconsistent about the
        // element TYPE (sometimes a textView, sometimes an otherElement for a
        // contenteditable div), so search all three query types for any of
        // those strings before falling back to "any editable control".
        let labels = ["Message input", "Ask anything", "Reply"]
        for q in [app.webViews.textFields, app.webViews.textViews, app.webViews.otherElements] {
            for label in labels {
                let m = q.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", label, label)).firstMatch
                if m.waitForExistence(timeout: 4) { return m }
            }
        }
        // Fallback: any web textField / textView (the input is the only edit
        // control on the chat home page).
        for q in [app.webViews.textFields.firstMatch,
                  app.webViews.textViews.firstMatch] {
            if q.waitForExistence(timeout: 3) { return q }
        }
        return nil
    }

    /// Polls until the chat input's vertical position has grown past `from.minY`
    /// by at least 120pt (i.e. it moved down — the SPA routed from the centered
    /// home hero to a bottom-anchored conversation input), or `timeout` elapses.
    private func waitForInputRepositioned(in app: XCUIApplication, from: CGRect,
                                          timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let i = findChatInput(in: app, timeout: 3), i.frame.minY > from.minY + 120 {
                return true
            }
            _ = XCTWaiter().wait(for: [XCTestExpectation()], timeout: 0.5)
        }
        return false
    }

    /// A plainly valid https URL entered in the URL box must load, NOT show
    /// "That URL is invalid." Runs on BOTH size classes (iPhone compact +
    /// iPad regular) so the iPad `BrowserNavigator` field — which previously
    /// had no "url-field" identifier and so was never exercised by the URL
    /// tests (they ran on an iPhone sim) — is covered. Guards against
    /// regressions in `normalizedURLString` / the submit path.
    ///
    /// Note: this types the URL literally via XCUITest, so it does NOT
    /// reproduce real-keyboard autocorrect/autocapitalize mangling (the
    /// suspected cause of the reported iPad-only 'invalid URL' on a real
    /// device — the toolbar TextField's input traits aren't always honored).
    /// It does guard the normalization + load path on both layouts.
    /// The in-app log viewer must show real `socks[n]` lines — i.e. it must
    /// actually prove, on-device, which hosts reached the tailnet proxy and what
    /// the proxy said. This is the only diagnostic channel on a device that
    /// can't be attached to a Mac, so if it comes up empty it is useless.
    func testLogViewerShowsSocksActivity() throws {
        let app = XCUIApplication()
        launchConnected(app)
        guard requireBrowserReady(app) else { return }

        // Let the home page load so there is proxy traffic to report.
        _ = app.webViews.firstMatch.waitForExistence(timeout: 30)

        // Logs moved into Settings -> Diagnostics when the toolbar's "more"
        // menu was deleted (PLAN §1.5); that menu was its only entry point.
        XCTAssertTrue(openSettings(app), "Settings should open")
        let logs = app.buttons["logs-button"]
        scrollToElement(logs, in: app)
        XCTAssertTrue(logs.waitForExistence(timeout: 10),
                      "Settings should offer a Logs row")
        logs.tap()

        XCTAssertTrue(app.navigationBars["Logs"].waitForExistence(timeout: 10),
                      "Log viewer should open")

        // The filter defaults to "socks", so the visible lines should be the
        // proxy-connection records. Wait for at least one to show up.
        let status = app.staticTexts["log-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 10), "Log status line should exist")

        let sawSocksLine = XCTWaiter().wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate { obj, _ in
                guard let app = obj as? XCUIApplication else { return false }
                // Any line mentioning the proxy relay counts.
                return app.staticTexts.allElementsBoundByIndex.contains {
                    $0.label.contains("socks[") || $0.label.contains("sockslog:")
                }
            }, object: app)], timeout: 30)

        attachScreenshot(app, named: sawSocksLine == .completed ? "logs-with-socks" : "logs-empty")
        XCTAssertEqual(sawSocksLine, .completed,
                       "The log viewer should show socks proxy activity after the " +
                       "home page loads — these lines are the on-device evidence " +
                       "of which hosts reached the tailnet proxy. Status line said: " +
                       "\(status.label)")

        app.buttons["log-done-button"].tap()
    }

    /// The Settings → Routing diagnostic must show that tailnet hosts are
    /// proxied and public hosts are NOT. This is the split tunnel that fixes
    /// the iPad `-1000` ("invalid URL") bug: sending public traffic through the
    /// tsnet SOCKS proxy is what breaks it, so a public host resolving to
    /// anything other than DIRECT is a regression.
    ///
    /// It's also the only on-device view of the routing rules — the iPad that
    /// reported the bug can't be attached to a Mac, so `log stream` is out.
    /// Requires a connection (the rules come from live peer status).
    func testRoutingDiagnosticSendsPublicHostsDirect() throws {
        let app = XCUIApplication()
        launchConnected(app)
        guard requireBrowserReady(app) else { return }

        // Settings lives behind the "more" menu on compact (iPhone) and a gear
        // on regular (iPad) — `openSettings` handles both.
        XCTAssertTrue(openSettings(app), "Settings should be reachable from the browser")
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10),
                      "Settings should open")

        // Routing is the last section (below Reset, so the primary controls
        // stay above the fold), and `Form` is lazy — its elements may not exist
        // at all until scrolled into view. Scroll until the test field appears.
        let field = app.textFields["routing-test-field"]
        for _ in 0..<8 where !field.exists {
            app.swipeUp()
        }

        // The split tunnel must be active, with real rules from peer status.
        XCTAssertFalse(app.staticTexts["routing-proxy-everything-warning"].exists,
                       "All traffic should not be proxied here: the Exit Node " +
                       "toggle must be off and -ProxyEverything unset")
        XCTAssertTrue(app.staticTexts["routing-rule-count"].waitForExistence(timeout: 15),
                      "Routing section should report the active proxy rules")
        XCTAssertTrue(field.waitForExistence(timeout: 10),
                      "Routing test field should exist (after scrolling to the Routing section)")

        func routeResult(for host: String) -> String {
            if !field.isHittable { app.swipeUp() }
            field.tap()
            field.clearAndType(text: host)
            let result = app.staticTexts["routing-test-result"]
            _ = result.waitForExistence(timeout: 5)
            return result.label
        }

        // Public hosts must load DIRECT — routing these through the proxy is
        // precisely the bug.
        for host in ["google.com", "www.google.com", "example.com", "1.1.1.1"] {
            let r = routeResult(for: host)
            attachScreenshot(app, named: "routing-\(host)")
            XCTAssertTrue(r.contains("DIRECT"),
                          "Public host \(host) must load DIRECT, not through the " +
                          "tailnet proxy (that is what causes the -1000 “invalid " +
                          "URL” failure). Got: \(r)")
        }

        // A tailnet IP must still be proxied, or tailnet browsing is broken.
        let tailnetIP = routeResult(for: "100.101.102.103")
        attachScreenshot(app, named: "routing-tailnet-ip")
        XCTAssertTrue(tailnetIP.contains("PROXY"),
                      "A tailnet (100.64.0.0/10) address must route through the " +
                      "proxy. Got: \(tailnetIP)")

        app.buttons["settings-done-button"].tap()
    }

    /// After the home page loads, tapping the page (e.g. to focus the chat
    /// input) must NOT crash the app. Guards against WebView/Page lifecycle
    /// regressions (notably the per-workspace `WKWebsiteDataStore` refactor).
    /// Requires the connected browser (auth key automates login).
    func testTapOnLoadedHomePageDoesNotCrash() throws {
        let app = XCUIApplication()
        launchConnected(app)

        guard requireBrowserReady(app) else { return }

        // Wait for the webview and the home page to finish loading.
        let webView = app.webViews.firstMatch
        guard webView.waitForExistence(timeout: 30) else {
            attachScreenshot(app, named: "tap-no-webview")
            XCTFail("Browser view / WKWebView did not appear once connected")
            return
        }
        let reached = waitForPageLoaded(in: app, contains: Self.defaultGatewayHostFragment, timeout: 60)
        attachScreenshot(app, named: reached ? "tap-before" : "tap-no-load")
        XCTAssertTrue(reached, "Home page should load before tapping")

        // Tap the center of the webview (where the chat UI renders its input).
        webView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        // Give any crash a moment to surface, then assert the app is still
        // running in the foreground and the webview is still present.
        _ = XCTWaiter().wait(for: [], timeout: 3)
        attachScreenshot(app, named: "tap-after")
        XCTAssertEqual(app.state, .runningForeground,
                       "App should not crash after tapping the loaded home page")
        XCTAssertTrue(webView.exists,
                      "WebView should still be present after the tap")
    }

    // MARK: - Helpers

    // MARK: Interactive login (null identity provider) helpers

    /// Waits for the connection gate's Login button (`login-button`) to
    /// appear — i.e. for the node to reach `NeedsLogin` and `StatusView` to
    /// render the Login button. Requires network reach to the control plane.
    @discardableResult
    private func waitForGateLoginButton(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
        app.buttons["login-button"].waitForExistence(timeout: timeout)
    }

    /// Completes the `ASWebAuthenticationSession` web-auth flow once the sheet
    /// has been (re)opened, authenticating as `testuser@nullid.fly.dev`:
    ///
    ///   1. Tailscale login page → type the email in the email field.
    ///   2. Tap "Sign in" (fallback: Return on the email field) → redirected
    ///      to the nullid.fly.dev provider.
    ///   3. nullid confirm page → tap "Log in" (the username is pre-filled).
    ///
    /// Returns true once the nullid confirm button has been tapped (the OAuth
    /// callback + tailnet-up then happen asynchronously; the caller waits for
    /// the browser chrome via `requireBrowserReady`). The auth sheet's web
    /// content is out-of-process, so `emailFieldTimeout` is generous (the
    /// a11y bridge can take 10–30s to expose the webview's elements).
    @discardableResult
    private func completeNullIdLogin(_ app: XCUIApplication,
                                     emailFieldTimeout: TimeInterval) -> Bool {
        // 1. Email field on the Tailscale login page.
        let emailField = app.webViews.textFields.firstMatch
        guard emailField.waitForExistence(timeout: emailFieldTimeout) else {
            attachScreenshot(app, named: "login-no-email-field")
            return false
        }
        emailField.tap()
        emailField.typeText("testuser@nullid.fly.dev")
        attachScreenshot(app, named: "login-email-typed")

        // 2. Submit → redirect to the nullid provider. Prefer the exposed
        //    "Sign in" button; fall back to Return if it isn't hittable in
        //    time (Return on the email field submits the form too).
        let signInButton = app.webViews.buttons["Sign in"]
        if signInButton.waitForExistence(timeout: 20) {
            signInButton.tap()
        } else {
            emailField.typeText("\n")
        }

        // 3. nullid confirm page: a single "Log in" button (the "Username:"
        //    field is pre-filled with the email's local part, "testuser").
        let nullidConfirm = app.webViews.buttons["Log in"]
        guard nullidConfirm.waitForExistence(timeout: 30) else {
            attachScreenshot(app, named: "login-no-nullid-confirm")
            return false
        }
        attachScreenshot(app, named: "login-nullid-confirm")
        nullidConfirm.tap()

        // 4. After the null-id provider confirms, Tailscale shows a device-
        //    authorization page on login.tailscale.com with a blue "Connect"
        //    button — authorizing THIS node to join the tailnet. It must be
        //    tapped to finish the OAuth callback. (On a relogin the device is
        //    still freshly registered — the state dir was wiped — so this page
        //    appears every time.)
        //
        //    The button's visible text is "Connect" but its accessibility
        //    label is "Connect device to tailnet" (extra SR-only context),
        //    so match by label-contains rather than an exact "Connect".
        //
        //    NOTE: do not shortcut this wait on browser chrome appearing;
        //    chrome can render while the replacement node is still finishing
        //    authentication. Always wait for the real Connect control and tap it.
        let connectButton = app.webViews.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Connect")).firstMatch
        if connectButton.waitForExistence(timeout: 40) {
            attachScreenshot(app, named: "login-connect-page")
            connectButton.tap()
        } else {
            // Device may have been auto-authorized (no Connect page). The
            // caller's success check distinguishes a real completion.
            attachScreenshot(app, named: "login-no-connect-page")
        }
        return true
    }

    /// Opens Settings. There is exactly one entry point now, in both states
    /// and both size classes: the `settings-button` gear — in the connection
    /// gate before connecting, and as `DashboardRootView`'s floating
    /// affordance after. Upstream also had a compact-toolbar "More" menu path;
    /// that toolbar is gone (PLAN §1.5), and so is the asymmetry.
    @discardableResult
    private func openSettings(_ app: XCUIApplication) -> Bool {
        guard app.buttons["settings-button"].waitForExistence(timeout: 10) else {
            attachScreenshot(app, named: "settings-no-entry-point")
            return false
        }
        app.buttons["settings-button"].tap()
        return app.navigationBars["Settings"].waitForExistence(timeout: 10)
    }

    /// After logout, the final session is replaced by a fresh node that drops
    /// to `NeedsLogin`. Normally this is the connection gate's `login-button`;
    /// accept a `LoginBanner` too if a view transition overlaps the state update.
    @discardableResult
    private func waitForNeedsLoginAgain(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate { obj, _ -> Bool in
            guard let app = obj as? XCUIApplication else { return false }
            return app.buttons["login-banner-button"].exists || app.buttons["login-button"].exists
        }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: app)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    // MARK: - Auth-key resolution (connected tests)

    /// Resolve the auth key for connected tests. `xcodebuild` does NOT forward
    /// arbitrary parent-shell environment variables to the UI-test runner, so
    /// reading `APERTURE_TEST_AUTHKEY` from `ProcessInfo.environment` alone is
    /// unreliable. Instead, prefer a key file that `scripts/run-uitests.sh` /
    /// the Makefile write from their own (shell) environment, which DOES see
    /// the variable. Resolution order:
    ///   1. `APERTURE_TEST_AUTHKEY` env var (when it happens to be present).
    ///   2. File at `APERTURE_TEST_AUTHKEY_FILE`, else `/tmp/aperture-test-authkey`.
    static func resolvedTestAuthKey() -> String? {
        let env = ProcessInfo.processInfo.environment
        if let k = env["APERTURE_TEST_AUTHKEY"], !k.isEmpty { return k }
        let path = env["APERTURE_TEST_AUTHKEY_FILE"] ?? "/tmp/aperture-test-authkey"
        guard let data = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let trimmed = data.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Whether the test node should be ephemeral. Defaults to "1" (ephemeral
    /// nodes auto-cleanup on close, ideal for CI); must match the key's type.
    static func resolvedTestEphemeral() -> String {
        let v = ProcessInfo.processInfo.environment["APERTURE_TEST_EPHEMERAL"]
        return (v?.isEmpty == false) ? v! : "1"
    }

    /// Form rows are lazily materialized, so a query made before scrolling may
    /// have neither the custom identifier nor SwiftUI's visible-title identity.
    private func settingsResetButton(in app: XCUIApplication) -> XCUIElement {
        let identified = app.buttons["reset-app-button"]
        return identified.exists ? identified : app.buttons["Reset app"].firstMatch
    }

    private func scrollToElement(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 where !element.exists || !element.isHittable {
            app.swipeUp()
        }
    }

    /// Waits for the brand header to appear. It is the app's only branding
    /// (there is no nav-bar title) and lives in the connection gate. Matches
    /// any element type via `descendants(matching: .any)` for robustness.
    @discardableResult
    private func waitForBrandHeader(_ app: XCUIApplication, timeout: TimeInterval = 20) -> Bool {
        let brandHeader = app.descendants(matching: .any)
            .matching(identifier: "latchkey-brand-header").firstMatch
        return brandHeader.waitForExistence(timeout: timeout)
    }

    /// Attach a screenshot of `app` to the current test. Call from inside a
    /// test method (which is `@MainActor`), e.g. on the failure path.
    func attachScreenshot(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Waits for `element` to become hittable (visible + tappable), which is a
    /// stronger condition than mere existence in the element tree.
    @discardableResult
    private func waitForHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "isHittable == YES")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        return result == .completed
    }

    private func tabOverviewShowsCount(_ expected: Int, in app: XCUIApplication) -> Bool {
        let predicate = NSPredicate { obj, _ -> Bool in
            guard let app = obj as? XCUIApplication else { return false }
            return app.descendants(matching: .any).matching(
                NSPredicate(format: "identifier BEGINSWITH %@", "tab-card-")
            ).count == expected
        }
        return XCTWaiter().wait(
            for: [XCTNSPredicateExpectation(predicate: predicate, object: app)],
            timeout: 10
        ) == .completed
    }

    /// Waits for at least one tab-overview card to show a title containing
    /// `substring` (the cards' title text is mirrored from the tab's WKWebView).
    /// Guards the tab-title-mirroring fix (#5b) — a regression would
    /// leave cards showing the host fallback (e.g. "ai") instead of the real
    /// SPA title.
    @discardableResult
    private func waitForTabCardTitle(in app: XCUIApplication, contains substring: String,
                                     timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate { obj, _ -> Bool in
            guard let app = obj as? XCUIApplication else { return false }
            // Tab-overview cards expose their title as a static text. Match any
            // static text whose label contains the substring and is plausible as
            // a card title (non-trivial length).
            let texts = app.staticTexts.allElementsBoundByIndex
            return texts.contains { $0.label.localizedCaseInsensitiveContains(substring) }
        }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: app)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Waits for the browser page to load by polling several native signals
    /// across both layouts:
    ///   - the compact URL pill's accessibility label ("Address: <host>") —
    ///     iPhone non-editing,
    ///   - the URL text field's value ("Enter URL" on iPad / "url-field" when
    ///     editing on iPhone),
    ///   - the WKWebView's identifier/label as a fallback.
    /// Returns true if any signal contained `substring` in time.
    @discardableResult
    private func waitForPageLoaded(in app: XCUIApplication, contains substring: String,
                                   timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate { obj, _ -> Bool in
            guard let app = obj as? XCUIApplication else { return false }
            // Compact URL pill (button) label: "Address: <host>".
            let pill = app.buttons["url-pill"]
            if pill.exists, pill.label.contains(substring) { return true }
            // URL text fields (either layout).
            for id in ["Enter URL", "url-field"] {
                let f = app.textFields[id]
                // Asking `value` of a zero-match XCUI query throws an internal
                // "Failed to get matching snapshot" test failure instead of
                // simply returning nil. The unified toolbar has no persistent
                // text field while its compact URL pill is showing.
                if f.exists, let val = f.value as? String, val.contains(substring) {
                    return true
                }
            }
            // Fallback: the WKWebView's identifier/label.
            let webView = app.webViews.firstMatch
            if webView.exists {
                if webView.identifier.contains(substring) || webView.label.contains(substring) { return true }
            }
            return false
        }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: app)
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        return result == .completed
    }

    // MARK: - Latchkey: web content process recovery (R7)

    /// iOS kills a web view's content process under memory pressure.
    /// Upstream turned that into a network-error page and never reloaded, so
    /// a routine memory kill looked like a tailnet outage. The page must come
    /// back by itself — a second load, not an error page. Hermetic: the
    /// harness serves its page from an in-app URL scheme handler.
    func testWebContentProcessTerminationReloadsAutomatically() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestProxyBounceHarness"]
        app.launch()

        let loads = app.staticTexts["bounce-load-count"]
        XCTAssertTrue(loads.waitForExistence(timeout: 20), "harness should render")
        XCTAssertTrue(waitForLabel(loads, "ONE LOAD", timeout: 20),
                      "the page should load once first; got '\(loads.label)'")

        app.buttons["simulate-web-content-termination"].tap()

        // The page counts its loads in sessionStorage, which survives a
        // reload in the same tab, so recovery shows up as a second load.
        XCTAssertTrue(waitForLabel(loads, "LOADS 2", timeout: 20),
                      "the page should reload by itself after its content process dies; got '\(loads.label)'")
        let errorPage = app.descendants(matching: .any)
            .matching(identifier: "nav-error-overlay").firstMatch
        XCTAssertFalse(errorPage.exists,
                       "an automatic recovery must not show the network-error page")
    }

    /// R3 review: KiroCrew opens windows blank and sets their location after
    /// an async call (`w = window.open('', '_blank'); … w.location = url`).
    /// With one web view, the app must hand WebKit a stand-in window (so
    /// window.open does not return null), catch its destination, load a
    /// same-origin one in place, and offer a way back.
    func testBlankPopupThatNavigatesLaterLoadsInPlaceWithWayBack() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestProxyBounceHarness"]
        app.launch()

        let loads = app.staticTexts["bounce-load-count"]
        XCTAssertTrue(waitForLabel(loads, "ONE LOAD", timeout: 20), "harness should load once")

        let open = app.webViews.buttons["Open popup later"]
        XCTAssertTrue(open.waitForExistence(timeout: 10), "popup button should render")
        open.tap()

        let popup = app.staticTexts["bounce-popup-status"]
        XCTAssertTrue(waitForLabel(popup, "POPUP popped-page", timeout: 15),
                      "the popup's later destination should load in place; got '\(popup.label)'")
        let back = app.buttons["return-to-dashboard-button"]
        XCTAssertTrue(back.waitForExistence(timeout: 5),
                      "a page opened by a new-window request must offer a way back")

        back.tap()
        XCTAssertTrue(app.webViews.buttons["Open popup later"].waitForExistence(timeout: 15),
                      "the way back should return to the original page")
        XCTAssertFalse(back.exists, "the way-back control should go away once used")
    }

    /// A popup that never navigates must not blank the page it came from,
    /// and window.open must still return a window rather than null.
    func testBlankPopupThatNeverNavigatesLeavesPageAlone() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestProxyBounceHarness"]
        app.launch()

        let loads = app.staticTexts["bounce-load-count"]
        XCTAssertTrue(waitForLabel(loads, "ONE LOAD", timeout: 20), "harness should load once")

        let open = app.webViews.buttons["Open blank popup"]
        XCTAssertTrue(open.waitForExistence(timeout: 10), "blank-popup button should render")
        open.tap()

        let popup = app.staticTexts["bounce-popup-status"]
        XCTAssertTrue(waitForLabel(popup, "POPUP blank-window", timeout: 10),
                      "window.open() should return a window, not null; got '\(popup.label)'")
        // Give a wrong implementation time to blank the page.
        Thread.sleep(forTimeInterval: 2)
        XCTAssertTrue(app.webViews.buttons["Open blank popup"].exists,
                      "the original page must still be showing")
        XCTAssertEqual(loads.label, "ONE LOAD", "the original page must not have reloaded")
        XCTAssertFalse(app.buttons["return-to-dashboard-button"].exists,
                       "nothing loaded in place, so there is nothing to return from")
    }

    private func waitForLabel(_ element: XCUIElement, _ label: String,
                              timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", label), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    // MARK: - Latchkey re-points

    /// The marker `DashboardRootView` draws once the dashboard is presented.
    /// Replaces the old "does the toolbar exist yet" check, since there is no
    /// toolbar any more.
    func connectedBrowserMarker(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: "connected-browser").firstMatch
    }

    /// Reloads the page. The reload button lived in the browser toolbar that
    /// PLAN §1.5 deleted, so this drives the Cmd-R command `DashboardRootView`
    /// keeps in its hidden command group instead.
    ///
    /// Needs a connected hardware keyboard in the simulator
    /// (`run-uitests.sh` enables it). If this ever proves flaky, the fallback
    /// is a debug-only reload affordance behind a launch argument — but do not
    /// add one speculatively; an untested test-only control is worse than the
    /// flake it was meant to prevent.
    func reloadPage(_ app: XCUIApplication) {
        app.typeKey("r", modifierFlags: .command)
    }
}

// MARK: - XCUIElement helpers

private extension XCUIElement {
    /// Clears the current text (by deleting back to empty) then types `text`.
    ///
    /// Each delete and each typed character drive the SwiftUI `Binding`, so
    /// this is the right way to exercise an `.onChange`-backed field in
    /// XCUITest (and also a `.onSubmit`-only field, where only the final
    /// Return would persist — which we deliberately avoid in the home-page
    /// persistence test).
    func clearAndType(text: String) {
        // Tap at the trailing edge, not the centre. Backspace only deletes
        // what is BEFORE the cursor, and a centre tap can land mid-text: the
        // old value's tail then survives and the new text is typed in front
        // of it. Seen as "https://<marker>.example.testgoblin.ts.net" — the
        // new value with the end of the old gateway URL still attached.
        coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        // Over-delete rather than deleting by `value.count`: the accessibility
        // `value` can disagree with the true editable text length (e.g. it may
        // report the placeholder), and pressing delete on an empty field is a
        // no-op, so a generous fixed count reliably clears the field.
        let deletes = String(repeating: XCUIKeyboardKey.delete.rawValue, count: 100)
        typeText(deletes)
        // Belt and braces: if a stray tap still left the cursor mid-text,
        // something is left. Move to the end once more and clear again.
        let placeholder = placeholderValue ?? ""
        if let left = value as? String, !left.isEmpty, left != placeholder {
            coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
            typeText(deletes)
        }
        typeText(text)
    }

}
