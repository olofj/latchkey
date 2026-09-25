// Copyright (c) Tailscale Inc & contributors
// SPDX-License-Identifier: BSD-3-Clause

//  Created by Jonathan Nobels on 2025-12-19.
//

import SwiftUI

struct SettingsView: View {
    /// Made once, for this sheet's lifetime (R32 review). The root creates
    /// the model inline in its sheet closure; owned as a plain observed
    /// object, a root re-render during a reset -- the workspace list changes
    /// under it -- would hand the sheet a fresh model with no activity and
    /// no pending alert.
    @StateObject private var viewModel: SettingsViewModel
    var dismissAction: () -> Void

    init(viewModel: @autoclosure @escaping () -> SettingsViewModel,
         dismissAction: @escaping () -> Void) {
        _viewModel = StateObject(wrappedValue: viewModel())
        self.dismissAction = dismissAction
    }

    @State private var showSignOutAlert: Bool = false
    @State private var showResetAlert: Bool = false
    @State private var routeTestHost: String = ""
    @State private var showingLogs: Bool = false
    @State private var showingGatewayPicker = false
    @State private var showingStatus = false
    @State private var showingNodeLog = false
    /// Applied once the picker has gone (two sheets cannot overlap).
    @State private var pendingGateway: String?
    @ObservedObject private var diagnostics = AppDiagnostics.shared

    var body: some View {
        settingsContainer
#if os(macOS)
        // Keep the shared, single-column grouped form used on iOS instead of
        // macOS's default two-column preferences layout. The latter turns
        // TextField prompts into a second label column and leaves large,
        // uneven gaps between these phone-sized settings sections.
        .frame(minWidth: 480, idealWidth: 520, minHeight: 560, idealHeight: 660)
#endif
#if canImport(UIKit)
        .presentationDetents([.medium, .large])
#endif
    }

    @ViewBuilder
    private var settingsContainer: some View {
#if os(macOS)
        VStack(spacing: 0) {
            HStack {
                Text("Settings")
                    .font(.title2.bold())
                Spacer()
                Button("Done") { dismissAction() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityLabel("Close Settings")
                    .accessibilityIdentifier("settings-done-button")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            Divider()
            settingsForm
                .formStyle(.grouped)
        }
#else
        NavigationStack {
            settingsForm
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        viewModel.commitGateway()
                        dismissAction()
                    }
                    .accessibilityIdentifier("settings-done-button")
                }
            }
        }
#endif
    }

    private var settingsForm: some View {
        Form {
            settingsSections
        }
        // The two ways out (R32), each behind a confirmation: getting back
        // in costs a computer (`kirocrew token`), or that and a Tailscale
        // login. Settings stays up, the button spinning, until the work is
        // done, and only then closes: the sign-in sheet waits for Settings to
        // go (M4), and a reset asks the control plane, which takes a moment.
        .alert("Sign out of the dashboard?", isPresented: $showSignOutAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Sign out", role: .destructive) {
                Task {
                    await viewModel.signOutOfDashboard()
                    dismissAction()
                }
            }
        } message: {
            Text("Your dashboard session ends on this device and at the gateway. Your tailnet node and gateway choice stay. To sign in again you need a new link from `kirocrew token` on a computer, or the dashboard's QR code.")
        }
        .alert("Reset Latchkey?", isPresented: $showResetAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Reset", role: .destructive) {
                Task {
                    await viewModel.resetApp()
                    // A failed tailnet logout keeps Settings up: its alert
                    // is next, and nothing has been deleted.
                    if viewModel.resetBlocked == nil { dismissAction() }
                }
            }
        } message: {
            Text("Signs out of the dashboard, logs this node out of Tailscale, and deletes everything Latchkey stored on this device: the node, website data, logs and the gateway choice. The app starts over, as on first run. Logging out expires the node's key; it stays listed as expired in the Tailscale admin console until removed there, which frees its name.")
        }
        // The tailnet logout failed (R32 review): the choice is the user's.
        // Deleting regardless would leave a node with a valid key in the
        // admin console for good, and the key that could still expire it in
        // the bin.
        .alert(TailnetLogout.failureTitle,
               isPresented: Binding(get: { viewModel.resetBlocked != nil },
                                    set: { if !$0 { viewModel.resetBlocked = nil } }),
               presenting: viewModel.resetBlocked) { _ in
            Button("Retry") {
                Task {
                    await viewModel.retryReset()
                    if viewModel.resetBlocked == nil { dismissAction() }
                }
            }
            Button("Delete anyway", role: .destructive) {
                viewModel.deleteAnyway()
                dismissAction()
            }
            // Closes Settings like the other two: the node stays, the
            // dashboard is signed out and reloads behind it (final review).
            Button("Cancel", role: .cancel) {
                viewModel.cancelReset()
                dismissAction()
            }
        } message: { reason in
            Text(TailnetLogout.failureMessage(reason))
        }
        .sheet(isPresented: $showingLogs) {
            LogViewer(dismissAction: { showingLogs = false })
        }
        .sheet(isPresented: $showingStatus) {
            let ws = viewModel.workspaceForSettings
            DiagnosticsView(workspace: ws, model: ws.model, session: ws.session,
                            discovery: ws.discovery, homePage: ws.homePage,
                            dismissAction: { showingStatus = false })
        }
        .sheet(isPresented: $showingNodeLog) {
            NodeLogView(dismissAction: { showingNodeLog = false })
        }
        .sheet(isPresented: $showingGatewayPicker, onDismiss: {
            if let origin = pendingGateway {
                pendingGateway = nil
                viewModel.choose(origin)
            }
        }) {
            GatewayPickerView(discovery: viewModel.workspaceForSettings.discovery,
                              model: viewModel.workspaceForSettings.model,
                              savedHost: URL(string: viewModel.homePage)?.host(),
                              autoSelectSingle: false,
                              sweepOnAppear: true,
                              onSelect: { origin in
                                  pendingGateway = origin
                                  showingGatewayPicker = false
                              },
                              onCancel: { showingGatewayPicker = false })
        }
        // However Settings goes away (Done, a swipe), the field is applied.
        // Idempotent: Done has already committed.
        .onDisappear { viewModel.commitGateway() }
    }

    @ViewBuilder
    private var settingsSections: some View {
                Section(header: Text("Name")) {
                    TextField("Tailnet HostName", text: $viewModel.tailnetHostName)
#if canImport(UIKit)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
#endif
                        .onSubmit {
                            viewModel.setTailnetHostName(viewModel.tailnetHostName)
                        }
                    Text("The name of this node on your Tailnet")
                        .font(Font.caption2)
                    // R6: KiroCrew pins identity-bound sessions to login plus
                    // node name, so a rename signs the dashboard out.
                    Text("Renaming it after you have signed in to the dashboard signs the dashboard out: KiroCrew ties sessions to your login and this name.")
                        .font(Font.caption2)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("hostname-rename-warning")
                }

                Section(header: Text("Gateway")) {
                    // F5 §7: the current gateway, the others this workspace
                    // has used, and any a sweep finds; one tap switches.
                    GatewaySwitcherRows(viewModel: viewModel,
                                        discovery: viewModel.workspaceForSettings.discovery,
                                        model: viewModel.workspaceForSettings.model,
                                        homePage: viewModel.workspaceForSettings.homePage,
                                        pickerShown: showingGatewayPicker,
                                        onSwitch: { origin in
                                            viewModel.choose(origin)
                                            // A refusal is shown in the section; Settings stays.
                                            if viewModel.gatewayError == nil { dismissAction() }
                                        })
                    TextField("gateway, or gateway.example.ts.net", text: $viewModel.homePage)
#if canImport(UIKit)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
#endif
                        .accessibilityIdentifier("home-page-field")
                        .onSubmit { viewModel.commitGateway() }
                    Button("Find gateways…") { showingGatewayPicker = true }
                        .disabled(viewModel.workspaceForSettings.model.proxyConfiguration == nil)
                        .accessibilityIdentifier("settings-find-gateways")
                    // A refused entry must say so here. `commitGateway` now
                    // goes through the same on-tailnet gate as the picker, so
                    // typing a public host is rejected rather than trusted --
                    // but a silent rejection would look like the field simply
                    // not working, and the owner would retype it.
                    if let error = viewModel.gatewayError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("settings-gateway-error")
                    }
                    Text("Applied when you press Return or close Settings.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                // R32. Two ways out, named for what they end: the dashboard
                // session (here), or all of it (Reset, below). Upstream's one
                // "Logout" deleted the workspace and said nothing about which.
                Section(header: Text("Dashboard")) {
                    Button {
                        showSignOutAlert = true
                    } label: {
                        HStack {
                            Text("Sign out of the dashboard")
                            if viewModel.activity == .signingOut {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    // Nothing to sign out of before a gateway is chosen.
                    .disabled(viewModel.activity != nil || !viewModel.workspaceForSettings.homePage.hasGateway)
                    .accessibilityIdentifier("signout-dashboard-button")
                    Text("Ends your dashboard session, here and at the gateway. Your tailnet node and gateway choice stay.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                // F6 §4.1a. The strict promise stays one switch away. No list
                // and no "allow this origin": the four hosts are a constant
                // in the binary, changed only in a reviewed commit.
                Section(header: Text("Privacy")) {
                    Toggle("Allow widget CDNs", isOn: Binding(
                        get: { viewModel.allowWidgetCDNs },
                        set: { viewModel.setAllowWidgetCDNs($0) }))
                        .accessibilityIdentifier("allow-widget-cdns-toggle")
                    Text("The dashboard loads only from its gateway. With this on, widgets may also load their code from \(ContentRules.allowedCDNHosts.joined(separator: ", ")), and each of those sees this phone's address. Fonts from Google are always blocked.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                // F3: what was shared and is not yet confirmed by a gateway.
                ShareSettingsSection(delivery: ShareDelivery.shared, dismissSettings: dismissAction)

                // The log viewer moved here when the browser toolbar was
                // deleted (PLAN §1.5). It had been reachable only from that
                // toolbar's "more" menu, which would have left an iPhone with
                // no way at all to read the app's own logs — the exact thing
                // §1.9 says to keep, and the only diagnostic available on a
                // device that cannot be attached to a Mac.
                Section(header: Text("Diagnostics")) {
                    Button {
                        showingStatus = true
                    } label: {
                        HStack {
                            Text("Status")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .accessibilityIdentifier("status-button")

                    Button {
                        showingNodeLog = true
                    } label: {
                        HStack {
                            Text("Node log (tsnet)")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .accessibilityIdentifier("node-log-button")

                    Button {
                        showingLogs = true
                    } label: {
                        HStack {
                            Text("Logs")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .accessibilityIdentifier("logs-button")

                    // R7: counted apart from network errors, which upstream
                    // showed as the same error page.
                    HStack {
                        Text("Web page restarts")
                        Spacer()
                        Text(diagnostics.webContentTerminations == 0
                             ? "none"
                             : "\(diagnostics.webContentTerminations) (\(diagnostics.webContentAutoReloads) reloaded automatically)")
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("diagnostics-web-content-restarts")
                }

                // Reset is the one way to leave the tailnet (R32 review): a
                // separate "Log out of Tailscale" deleted the same things
                // but skipped the dashboard sign-out, leaving a live 30-day
                // session at the gateway.
                Section(header: Text("Reset")) {
                    StatusButton(text: "Reset app",
                                 action: { showResetAlert = true },
                                 color: .red,
                                 isLoading: viewModel.activity == .resetting)
                        .disabled(viewModel.activity != nil)
                        .accessibilityIdentifier("reset-app-button")
                    Text("Signs out of the dashboard, logs this node out of Tailscale, and deletes everything stored on this device. Starts over as on first run.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                routingSection
    }

    // MARK: - Routing (split tunnel) diagnostic

    /// Shows which hosts are routed through the tsnet proxy and lets the user
    /// test any host. This exists because the iPad that hit the `-1000`
    /// ("invalid URL") bug can't be attached to a Mac, so `log stream` is
    /// unavailable — this is the on-device ground truth for the split tunnel.
    @ViewBuilder
    private var routingSection: some View {
        Section(header: Text("Routing")) {
            if viewModel.proxyEverything {
                Text("⚠️ ALL traffic is going through the tailnet (-ProxyEverything override). Public sites only work if something is carrying them out of the tailnet — otherwise they fail with “invalid URL”.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("routing-proxy-everything-warning")
            } else if let policy = viewModel.proxyPolicy {
                Text("Tailnet hosts go through the proxy; everything else loads directly.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(policy.matchDomains.count) proxy rule(s)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("routing-rule-count")
                DisclosureGroup("Show rules") {
                    ForEach(policy.matchDomains, id: \.self) { rule in
                        Text(rule)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .accessibilityIdentifier("routing-rules-disclosure")
                if !policy.shortNamesWithheldAsPublicTLD.isEmpty {
                    Text("Short names also matching a public domain (reached via their full tailnet name): \(policy.shortNamesWithheldAsPublicTLD.joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("routing-withheld-names")
                }
            } else {
                Text("Not connected yet — no routing rules applied.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("routing-not-connected")
            }

            TextField("Test a host or URL", text: $routeTestHost)
#if canImport(UIKit)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
#endif
                .accessibilityIdentifier("routing-test-field")
            if let explanation = viewModel.routeExplanation(for: routeTestHost) {
                Text(explanation)
                    .font(.caption.monospaced())
                    .foregroundStyle(explanation.contains("DIRECT") ? Color.secondary : Color.green)
                    .accessibilityIdentifier("routing-test-result")
            }
        }
    }

}
