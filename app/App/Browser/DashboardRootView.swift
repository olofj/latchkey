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
//  single-purpose (PLAN §1.3) — one window, one destination, no browser
//  chrome. The one strip it keeps is the app bar above the page (F15).
//
//  `TabManager` still owns the one page's WKWebView lifecycle. It no longer
//  persists anything: every cold start opens the gateway origin (R2).
//

import SwiftUI
import WebKit
import TailscaleKit

struct DashboardRootView: View {
    @ObservedObject var workspaceManager: WorkspaceManager

    /// Settings is global (reachable from both the gate and the dashboard), so
    /// its sheet lives here.
    @State private var showingSettings = false
    /// The token sheet waits while Settings is up, and until Settings has
    /// finished dismissing: two sheets cannot stack (M4 review).
    @State private var tokenSheetAllowed = true

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
                // one), but keep the view tree valid rather than crashing. It
                // says something anyway (F4 §4.7 G1): an unreachable state that
                // renders a bare spinner is indistinguishable, if it ever is
                // reached, from the blank screens this feature removes.
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Starting Latchkey…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .background {
            if let ws = presentedWorkspace {
                TokenSheetHost(session: ws.session, allowed: tokenSheetAllowed)
            }
        }
        .onChange(of: showingSettings) { _, showing in
            if showing { tokenSheetAllowed = false }
        }
        .sheet(isPresented: $showingSettings, onDismiss: { tokenSheetAllowed = true }) {
            if let ws = presentedWorkspace {
                SettingsView(
                    // Evaluated once: SettingsView keeps it as a StateObject
                    // across re-renders of this root (R32 review).
                    viewModel: SettingsViewModel(
                        workspace: ws,
                        deleteSession: {
                            // A reset deletes the session (R32).
                            workspaceManager.deleteWorkspace(id: ws.id)
                        }
                    ),
                    dismissAction: { showingSettings = false }
                )
            }
        }
    }
}

/// Presents the dashboard's sign-in sheet (M4) from the root, next to
/// Settings rather than under it, so a token request that arrives while
/// Settings is open is shown when Settings closes instead of being lost.
private struct TokenSheetHost: View {
    @ObservedObject var session: SessionManager
    let allowed: Bool

    var body: some View {
        Color.clear
            .sheet(isPresented: Binding(
                get: { session.isTokenSheetPresented && allowed },
                set: { if !$0 { session.isTokenSheetPresented = false } }
            )) {
                TokenEntrySheet(session: session)
                    .onAppear { session.isTokenSheetOnScreen = true }
                    .onDisappear { session.isTokenSheetOnScreen = false }
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
                    session: workspace.session,
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

/// The app bar, the node's banners and one web view below them. Nothing of
/// the app's is drawn over the page (F15).
private struct DashboardContent: View {
    let workspace: Workspace
    @ObservedObject var homePage: HomePage
    @ObservedObject var model: TSNetModel
    @ObservedObject var tab: BrowserTab
    @ObservedObject var statusViewModel: StatusViewModel
    @ObservedObject var session: SessionManager
    let onSettings: () -> Void
    @State private var showingGatewayPicker = false
    /// A gateway chosen in the Find sheet, applied once the sheet is gone:
    /// the new gateway's page may ask for a token at once, and two sheets
    /// cannot overlap (M5 review; the same rule as Settings, M4).
    @State private var pendingGateway: String?
    /// How much of the bottom safe area the page takes (Olof, F13): 34pt on
    /// an iPhone 17 leaves 24, still clear of the home indicator.
    static let bottomReclaim: CGFloat = 10
    /// The bottom safe area without the keyboard's, measured by a reader that
    /// ignores the keyboard. Unmeasured, it is taken as "no keyboard".
    @State private var containerBottom = CGFloat.infinity

    var body: some View {
        Group {
            if homePage.hasGateway {
                NavigationStack {
                    // The stack hands its content the window's bottom safe area
                    // again, whatever is ignored outside it (F13): that is what
                    // ended the page 34pt above the screen edge. The page takes
                    // 10pt of it back and stays clear of the home indicator.
                    // With the keyboard up the inset is the keyboard's, which
                    // the stack already keeps the page above: padding by it
                    // again left the page no height at all, a black screen.
                    GeometryReader { geo in
                        let inset = geo.safeAreaInsets.bottom
                        let keyboardUp = inset > containerBottom + 0.5
                        gatewayContent
                            .padding(.bottom, keyboardUp ? 0 : max(0, inset - Self.bottomReclaim))
                            .ignoresSafeArea(.container, edges: .bottom)                    }
                    .background {
                        GeometryReader { geo in
                            Color.clear.onChange(of: geo.safeAreaInsets.bottom, initial: true) {
                                containerBottom = $1
                            }
                        }
                        .ignoresSafeArea(.keyboard)
                    }
#if canImport(UIKit)
                    .toolbar(.hidden, for: .navigationBar)
#endif
                }
            } else {
                // First run (M5): no gateway yet. Its own navigation stack,
                // not nested in the dashboard's toolbar-less one (M5 review).
                GatewayPickerView(discovery: workspace.discovery, model: model, savedHost: nil,
                                  autoSelectSingle: true,
                                  onSelect: { workspace.selectGateway($0) })
            }
        }
        // Lets the navigation stack reach the screen edge; the page's own
        // bottom edge is decided inside it, above.
        .ignoresSafeArea(.container, edges: .bottom)
        // No overlays (F15). Eight used to be painted over the page, at six
        // alignments, as though its corners were ours; the dashboard draws its
        // own controls there, and the gear landed on its notification bell.
        // The three controls went into the app bar (`AppBar`); the rest are
        // test instruments, below, in the status-bar corner. Do not add an
        // overlay back:
        // L1's testNothingOfOursSitsOnThePageAndSettingsIsReachable names any
        // hittable control of ours whose frame meets the web view's.
        // M5.5: re-probe when the chosen gateway is unreachable.
        .sheet(isPresented: $showingGatewayPicker, onDismiss: {
            if let origin = pendingGateway {
                pendingGateway = nil
                workspace.selectGateway(origin)
            }
        }) {
            GatewayPickerView(discovery: workspace.discovery, model: model,
                              savedHost: URL(string: homePage.url)?.host(),
                              autoSelectSingle: false,
                              sweepOnAppear: true,
                              onSelect: { origin in
                                  pendingGateway = origin
                                  showingGatewayPicker = false
                              },
                              onCancel: { showingGatewayPicker = false })
        }
        // Test instruments, never controls, and never over the page: one point
        // of text each, in the top-leading corner of the status-bar strip.
        // Behind the web view was tried first and is not enough -- a view the
        // page covers still wins accessibility's hit test there, and L1's sweep
        // found all four "on the page". Testing builds only: "Connected
        // Browser" used to ship, as an invisible element VoiceOver read out
        // over the dashboard's bottom-right corner (F15 §9).
#if LATCHKEY_TEST_HOOKS
        .background(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                // How many times the connecting block became visible for this
                // tab (F4 §4.7). A block that flashes up and away between two
                // looks is invisible to a poll but not to this number -- which
                // is the failure mode the 300 ms delay could introduce.
                Text("connecting-shown:\(tab.viewModel.connectingShownCount)")
                    .accessibilityIdentifier("page-connecting-shown-count")
                // How many times the page asked for a token, so a sheet that
                // flashes up and away between two looks is caught.
                Text("\(session.authRequiredEvents)")
                    .accessibilityIdentifier("session-auth-required-count")
                // A concrete element meaning "the dashboard is up". An
                // identifier applied to a container view is not reliably surfaced.
                Text("Connected Browser")
                    .accessibilityIdentifier("connected-browser")
                if TSNetManager.tcpChaosTestRequested(),
                   let status = workspace.model.tcpChaosTestStatus {
                    Text(status)
                        .accessibilityIdentifier("tcp-chaos-test-status")
                }
#if canImport(UIKit)
                // F9 §0.2 / F15 §6: the window's safe-area top, for L1. It reads
                // the window, so where it sits does not matter.
                if TestHooks.flag("-UITestReportSafeArea") {
                    WindowSafeAreaProbe().frame(width: 1, height: 1)
                }
#endif
            }
            .font(.system(size: 1))
            .lineLimit(1)
            .opacity(0.01)
            .allowsHitTesting(false)
            .ignoresSafeArea()
        }
#endif
        // With the toolbar gone, these are the hardware-keyboard paths to
        // Settings (which owns the log viewer) and to a reload. Defined here
        // so they stay available regardless of what has focus inside the web
        // content.
        .background {
#if !os(macOS)
            Group {
                Button("Settings") { onSettings() }
                    .keyboardShortcut(",", modifiers: .command)
                Button("Reload") { tab.viewModel.reload() }
                    .keyboardShortcut("r", modifiers: .command)
            }
            .hidden()
#endif
        }
    }

    /// The sign-in button in the app bar. Keyed on the sheet being ON SCREEN,
    /// not requested: a deferred request must not hide the only way in (M4
    /// review). Not while the node itself is down: its banner comes first, and
    /// no dashboard sign-in can work until it is back (R31 review).
    private var showsSignIn: Bool {
        session.state == .needsToken && !session.isTokenSheetOnScreen
            && !statusViewModel.needsAuth && !statusViewModel.needsMachineAuth
    }

    private var gatewayContent: some View {
        // The app bar, then the page (F15). The banners are between them: in
        // the layout like the page, never over it, and they stay when the bar
        // retracts (F15 §9 argues their place).
        AppBarColumn(model: tab.viewModel, controller: tab.viewModel.appBar,
                     showsSignIn: showsSignIn,
                     onSignIn: { session.isTokenSheetPresented = true },
                     onSettings: onSettings) {
            // The node's own trouble first, in the layout rather than over it
            // (R31 review): an overlay covered the gateway banner's buttons and
            // was itself covered by the sign-in capsule.
            if statusViewModel.needsAuth {
                // Mid-session NeedsLogin -- the node key expired, or was
                // expired by an admin (R31): Login re-authenticates in place.
                LoginBanner(
                    authSessionEndedGeneration: statusViewModel.authSessionEndedGeneration,
                    onLogin: { statusViewModel.showAuth() }
                )
            } else if statusViewModel.needsMachineAuth {
                MachineAuthBanner()
            }
            if homePageAvailability == .unavailable {
                GatewayUnreachableBanner(onSettings: onSettings,
                                         onFindGateways: { showingGatewayPicker = true })
            }
            // The one picker presentation lives here (F4 §4.7), so Find, Change,
            // the connecting hint's button and the error page's all go through
            // it and two sheets can never overlap (M5 review). The load is
            // stopped first, which moves the page to a failed state with cause
            // `stopped` — so cancelling the picker lands on an error page with
            // Try again, never back on a blank web view.
            BrowserView(model: tab.viewModel,
                        gatewayMissing: homePageAvailability == .unavailable,
                        onChooseGateway: {
                            tab.viewModel.stopForGatewayChange()
                            showingGatewayPicker = true
                        })
                .frame(minHeight: 0, maxHeight: .infinity)
                .layoutPriority(-1)
            // R31, R33: the two clocks that end the app, warned about ahead.
            // At the bottom: the top edge is the app bar's and the node's
            // banners'.
            ForEach(expiryWarnings, id: \.self) { message in
                Label(message, systemImage: "clock.badge.exclamationmark")
                    .font(.subheadline)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.thinMaterial)
                    .overlay(alignment: .top) { Divider() }
                    .accessibilityIdentifier("expiry-warning")
            }
        }
        .onChange(of: homePageAvailability) { _, availability in
            loadGatewayIfRecovered(availability)
        }
        // State, not only transitions: if the gateway became available before
        // this view existed, onChange never fires and the fallback page would
        // stay (M5: a relaunch hit exactly that).
        .onAppear { loadGatewayIfRecovered(homePageAvailability) }
    }

    /// Recovers from the unreachable-gateway fallback when the gateway shows
    /// up later.
    ///
    /// If the gateway is not yet a peer when the first load is decided,
    /// `HomePageAvailabilityChecker` sends the tab to `about:blank`. That
    /// commits a URL, which makes `BrowserViewModel.loadInitial` refuse every
    /// subsequent attempt — by design, so a status poll can't yank a page the
    /// user is reading back to the home page. The side effect is that a
    /// gateway that finishes booting a few seconds after the app does leaves
    /// the user on a permanently blank page with a banner, recoverable only by
    /// relaunching.
    ///
    /// The tailnet is a slow, racy thing to wait on, so the ordering is not
    /// rare: the peer list can easily arrive after the first load decision.
    /// Narrow on purpose — it only fires on the unavailable → available edge,
    /// and only when the blank fallback is what is actually on screen, so it
    /// can never interrupt a real page.
    private func loadGatewayIfRecovered(_ availability: HomePageAvailability) {
        guard availability == .available,
              tab.viewModel.url == HomePageAvailabilityChecker.unreachableFallbackURL,
              let gateway = URL(string: homePage.url)
        else { return }
        logger.log("Gateway \(gateway.redactedForLog) appeared in the tailnet; leaving the fallback page")
        tab.viewModel.load(url: gateway)
    }

    /// Only what is still ahead: an expired key has the login banner.
    private var expiryWarnings: [String] {
        Expiry.warnings(keyExpiry: Expiry.parseKeyExpiry(model.localStatus?.SelfStatus?.KeyExpiry),
                        profileExpiry: DiagnosticsView.profileExpiry, now: Date())
            .filter(Expiry.isAhead)
            .map(Expiry.message)
    }

    private var homePageAvailability: HomePageAvailability {
        HomePageAvailabilityChecker.check(
            urlString: homePage.url,
            status: model.localStatus)
    }
}

/// Shown only after a same-origin new-window request loaded in place
/// (KiroCrew's "pop out chat", "open in new tab"). One window and no back
/// button would otherwise leave the user stranded on that page (R3 review).
/// The app bar's leading item (F15), styled to match the gear.
struct ReturnToDashboardAffordance: View {
    @ObservedObject var model: BrowserViewModel

    var body: some View {
        if model.showsReturnToDashboard {
            Button {
                model.returnToDashboard()
            } label: {
                Label("Dashboard", systemImage: "chevron.backward")
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.thinMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .accessibilityIdentifier("return-to-dashboard-button")
        }
    }
}

/// Shown above the page when the configured gateway is not a node in this
/// tailnet. Upstream sent the tab to the Aperture signup site instead; Kiro
/// Roam has nowhere useful to send it, so it points at Settings, where the
/// gateway address can be corrected. M5 replaces this with the picker.
private struct GatewayUnreachableBanner: View {
    let onSettings: () -> Void
    let onFindGateways: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("No KiroCrew gateway with this name is in your tailnet.")
                .font(.subheadline.weight(.medium))
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
            Button("Find") { onFindGateways() }
                .font(.subheadline.weight(.semibold))
                .accessibilityIdentifier("gateway-unreachable-find-button")
            Button("Change") { onSettings() }
                .font(.subheadline.weight(.semibold))
                .accessibilityIdentifier("gateway-unreachable-settings-button")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.thinMaterial)
        .overlay(alignment: .bottom) { Divider() }
        // `.contain`: without it the banner's identifier replaced its buttons'
        // own, and a UI test could not find Find (M5).
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home-page-warning-banner")
    }
}

/// Inline "login required" banner shown over the page if the node drops to
/// `NeedsLogin` after having connected (e.g. the user logged out).
/// An admin revoked this device's approval mid-session (R31): the node waits
/// at NeedsMachineAuth and nothing loads. There is nothing to do in the app,
/// so no button -- it says where the fix is, and goes away by itself when the
/// device is approved again (the gate's text, R17, for a dashboard already up).
private struct MachineAuthBanner: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.badge.exclamationmark")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Waiting for approval")
                    .font(.subheadline.weight(.medium))
                Text("An admin must approve this device in the Tailscale admin console. The dashboard comes back by itself.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.thinMaterial)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("needs-machine-auth-banner")
    }
}

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
