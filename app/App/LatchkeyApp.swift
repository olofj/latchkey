// Copyright (c) Tailscale Inc & contributors
// SPDX-License-Identifier: BSD-3-Clause

//
//  LatchkeyApp.swift
//  Latchkey
//
//  Created by Jonathan Nobels on 2025-12-16.
//

import SwiftUI
import AppIntents
import TailscaleKit

@main
struct LatchkeyApp: App {
    /// A test harness owns the window instead of the dashboard (R15: test
    /// builds only; always false elsewhere).
    private static var harnessMode: Bool {
        TestHooks.flag("-TimingHarness") || TestHooks.flag("-UITestProxyBounceHarness")
    }

    @Environment(\.scenePhase) private var scenePhase

    @State private var workspaceManager: WorkspaceManager?

    init() {
        // Nothing this app fetches with URLSession belongs on disk: LocalAPI
        // responses carry the node's state and, while it waits for a login,
        // the login link (R29 review found them in Cache.db). TailscaleKit's
        // LocalAPI sessions are ephemeral now; this keeps any session that
        // falls back to the shared cache in memory too. WebKit has its own.
        URLCache.shared = URLCache(memoryCapacity: 4 << 20, diskCapacity: 0)

        // Only construct the (heavy) WorkspaceManager — which initializes the
        // process logger and starts tsnet nodes — in normal mode. Harness modes
        // bypass it and own their node lifecycle.
        if !Self.harnessMode {
            _workspaceManager = State(initialValue: WorkspaceManager())
        }
    }

    var body: some Scene {
        WindowGroup {
#if LATCHKEY_TEST_HOOKS
            if TestHooks.flag("-TimingHarness") {
                TimingHarnessView()
            } else if TestHooks.flag("-UITestProxyBounceHarness") {
                ProxyBounceTestHarnessView()
            } else if let workspaceManager {
                DashboardRootView(workspaceManager: workspaceManager)
            } else {
                ProgressView()
            }
#else
            if let workspaceManager {
                DashboardRootView(workspaceManager: workspaceManager)
            } else {
                ProgressView()
            }
#endif
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Don't fan scenePhase to WorkspaceManager in harness mode (there
            // is none); the harness manages its own node lifecycles.
            guard !Self.harnessMode else { return }
            guard let workspaceManager else { return }
            switch newPhase {
            case .background:
                workspaceManager.willEnterBackground()
            case .inactive:
                // Do NOT tear down the node on .inactive. That scenePhase
                // fires for Control Center, the app-switcher peek, an incoming
                // call, a notification banner, etc. — the app is still in the
                // foreground. Tearing the tsnet node down and recreating it on
                // the return to .active is expensive AND dangerous mid-login:
                // it recreated the node (new auth URL) while an
                // ASWebAuthenticationSession sheet was still open on the OLD
                // url → the OAuth completed on the control plane but the new
                // node wasn't watching that callback → silent login failure
                // (the stale-URL bug). Only a real .background disconnects;
                // .active reconnects (a no-op via the startInFlight guard if
                // we never went to background).
                break
            case .active:
                workspaceManager.willEnterForeground()
            @unknown default:
                break
            }
        }
    }
}
