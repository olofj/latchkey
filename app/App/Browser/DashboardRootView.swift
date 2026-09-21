// Copyright (c) Tailscale Inc & contributors
// SPDX-License-Identifier: BSD-3-Clause

//
//  DashboardRootView.swift
//  Latchkey
//
//  The root window. Until the workspace's tailnet first reaches `Running` it
//  shows `ConnectionGateView` (the login screen); after that it shows one
//  full-screen WKWebView pointed at the KiroCrew gateway, for the rest of the
//  session. Later transport outages are left to tsnet and do not replace
//  browser UI.
//
//  Upstream this was `TabbedBrowserView`: a Safari-style multi-tab browser
//  with an address bar, bookmarks and a tab overview. Latchkey is
//  single-purpose (PLAN §1.3) — one window, one destination, no chrome.
//
//  `TabManager` survives the tab removal on purpose. It owns the persistence
//  that restores the page you were last looking at, which is exactly what a
//  phone app wants after being jetsammed; it is now capped at one tab.
//

import SwiftUI
import WebKit
import TailscaleKit

struct DashboardRootView: View {
    @ObservedObject var workspaceManager: WorkspaceManager

    /// Settings is global (reachable from both the gate and the dashboard), so
    /// its sheet lives here.
    @State private var showingSettings = false

    private var presentedWorkspace: Workspace? {
        workspaceManager.activeWorkspace
    }

    var body: some View {
        Group {
            if let ws = presentedWorkspace {
                WorkspaceRoot(workspace: ws, showingSettings: $showingSettings)
                    // Key by workspace id so replacing the active workspace
                    // tears down this subtree and builds a fresh
                    // `WorkspaceRoot` with its own `@StateObject` tab manager,
                    // status view model and WKWebView. Within one workspace the
                    // id is stable, so the web view survives.
                    .id(ws.id)
            } else {
                // No workspace — never happens (WorkspaceManager always seeds
                // one), but keep the view tree valid rather than crashing.
                ProgressView()
            }
        }
        .sheet(isPresented: $showingSettings) {
            if let ws = presentedWorkspace {
                SettingsView(
                    viewModel: SettingsViewModel(
                        workspace: ws,
                        deleteSession: {
                            // Logout explicitly deletes the session.
                            workspaceManager.deleteWorkspace(id: ws.id)
                        }
                    ),
                    dismissAction: { showingSettings = false }
                )
            }
        }
    }
}

// MARK: - Per-workspace root (gate ⇄ dashboard)

/// The root for a single workspace: the connection gate until its tailnet
/// first reaches `Running`, then the dashboard for the rest of the session.
/// Observes the workspace's `StatusViewModel` directly so the `running` flip
/// is tracked live.
private struct WorkspaceRoot: View {
    let workspace: Workspace
    @StateObject private var tabManager: TabManager
    @StateObject private var statusViewModel: StatusViewModel
    @Binding var showingSettings: Bool

    /// Flips to true the first time this workspace's tailnet reaches `Running`
    /// and stays true — so a transient reconnect doesn't kick back to the gate.
    @State private var hasConnected = false

    init(workspace: Workspace, showingSettings: Binding<Bool>) {
        self.workspace = workspace
        // Resolve the workspace-owned session lazily here (first render), NOT
        // in `Workspace.init` before the window exists. This preserves the
        // gesture-recognizer crash fix from upstream.
        _tabManager = StateObject(wrappedValue: workspace.tabManager)
        _statusViewModel = StateObject(wrappedValue: workspace.statusViewModel)
        self._showingSettings = showingSettings
    }

    var body: some View {
        Group {
            if hasConnected, let tab = tabManager.currentTab {
                DashboardContent(
                    workspace: workspace,
                    homePage: workspace.homePage,
                    model: workspace.model,
                    tab: tab,
                    statusViewModel: statusViewModel,
                    onSettings: { showingSettings = true }
                )
            } else {
                ConnectionGateView(
                    statusViewModel: statusViewModel,
                    onSettings: { showingSettings = true }
                )
            }
        }
        .onAppear {
            if statusViewModel.running { hasConnected = true }
            ensureFreshTab()
        }
        .onChange(of: statusViewModel.running) { _, running in
            if running { hasConnected = true }
            ensureFreshTab()
        }
        .onDisappear {
            tabManager.unloadAllWebViews()
        }
    }

    /// Ensure there is a page to show once connected, rather than an empty
    /// pane. A no-op when a tab already exists, which is the normal case —
    /// including first launch, where `TabManager.init` seeds one.
    private func ensureFreshTab() {
        guard hasConnected, tabManager.tabCount == 0 else { return }
        tabManager.openChatTab()
    }
}

// MARK: - Dashboard (connected)

/// One full-screen web view, plus the two things allowed to appear over it:
/// the log viewer and the tailnet login banner.
private struct DashboardContent: View {
    let workspace: Workspace
    @ObservedObject var homePage: HomePage
    @ObservedObject var model: TSNetModel
    @ObservedObject var tab: BrowserTab
    @ObservedObject var statusViewModel: StatusViewModel
    let onSettings: () -> Void

    /// In-app log viewer. The only way to read the app's logs on a device that
    /// cannot be attached to a Mac.
    @State private var showingLogs = false

    var body: some View {
        NavigationStack {
            dashboardContent
#if canImport(UIKit)
                .toolbar(.hidden, for: .navigationBar)
#endif
        }
        // The page owns the full screen, including the bottom safe area.
        // Without this the root layout leaves an app-background strip beneath
        // dark web content.
        .ignoresSafeArea(.container, edges: .bottom)
        .overlay(alignment: .bottomTrailing) {
            // A concrete accessibility element for UI automation. An
            // identifier applied to a container view is not reliably surfaced.
            Text("Connected Browser")
                .accessibilityIdentifier("connected-browser")
                .opacity(0.01)
        }
        .overlay(alignment: .bottomLeading) {
            if (ProcessInfo.processInfo.arguments.contains("-UITestDefunctLoopback")
                || ProcessInfo.processInfo.arguments.contains("-UITestShutdownTCPConnections")),
               let status = workspace.model.tcpChaosTestStatus {
                Text(status)
                    .accessibilityIdentifier("tcp-chaos-test-status")
                    .opacity(0.01)
            }
        }
        .sheet(isPresented: $showingLogs) {
            LogViewer(dismissAction: { showingLogs = false })
        }
        // With the toolbar gone, these shortcuts are the only way to reach
        // Settings and Logs from a hardware keyboard. Defined here so they
        // stay available regardless of what has focus inside the web content.
        .background {
#if !os(macOS)
            Group {
                Button("Settings") { onSettings() }
                    .keyboardShortcut(",", modifiers: .command)
                Button("Logs") { showingLogs = true }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                Button("Reload") { tab.viewModel.reload() }
                    .keyboardShortcut("r", modifiers: .command)
            }
            .hidden()
#endif
        }
    }

    private var dashboardContent: some View {
        VStack(spacing: 0) {
            if homePageAvailability == .unavailable {
                GatewayUnreachableBanner(onSettings: onSettings)
            }
            BrowserView(model: tab.viewModel)
                .frame(minHeight: 0, maxHeight: .infinity)
                .layoutPriority(-1)
        }
        .overlay(alignment: .top) {
            if statusViewModel.needsAuth {
                LoginBanner(
                    authSessionEndedGeneration: statusViewModel.authSessionEndedGeneration,
                    onLogin: { statusViewModel.showAuth() }
                )
            }
        }
    }

    private var homePageAvailability: HomePageAvailability {
        HomePageAvailabilityChecker.check(
            urlString: homePage.url,
            status: model.localStatus)
    }
}

/// Shown above the page when the configured gateway is not a node in this
/// tailnet. Upstream sent the tab to the Aperture signup site instead; Kiro
/// Roam has nowhere useful to send it, so it points at Settings, where the
/// gateway address can be corrected. M5 replaces this with the picker.
private struct GatewayUnreachableBanner: View {
    let onSettings: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("No KiroCrew gateway with this name is in your tailnet.")
                .font(.subheadline.weight(.medium))
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
            Button("Change") { onSettings() }
                .font(.subheadline.weight(.semibold))
                .accessibilityIdentifier("gateway-unreachable-settings-button")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.thinMaterial)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityIdentifier("home-page-warning-banner")
    }
}

/// Inline "login required" banner shown over the page if the node drops to
/// `NeedsLogin` after having connected (e.g. the user logged out).
private struct LoginBanner: View {
    let authSessionEndedGeneration: UInt64
    let onLogin: () -> Void

    /// Spins the moment the Login button's action fires — tap feedback, since
    /// the button is small in a thin banner. The banner disappears when login
    /// succeeds (`needsAuth` → false), so this only needs a safety timeout to
    /// return the button to tappable if the sheet never opens.
    @State private var isStartingLogin = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .foregroundStyle(.orange)
            Text("Login Required")
                .font(.subheadline.weight(.medium))
            Spacer()
            Button {
                isStartingLogin = true
                onLogin()
                Task {
                    try? await Task.sleep(nanoseconds: 120_000_000_000)
                    isStartingLogin = false
                }
            } label: {
                if isStartingLogin {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Login")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .accessibilityIdentifier("login-banner-button")
            .onChange(of: authSessionEndedGeneration) { _, _ in
                isStartingLogin = false
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.thinMaterial)
        .overlay(alignment: .bottom) { Divider() }
    }
}
