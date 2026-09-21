// Copyright (c) Tailscale Inc & contributors
// SPDX-License-Identifier: BSD-3-Clause

//  Created by Jonathan Nobels on 2025-12-19.
//

import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    var dismissAction: () -> Void

    @State private var showLogoutAlert: Bool = false
    @State private var routeTestHost: String = ""

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
        .alert("Logout", isPresented: $showLogoutAlert) {
            logoutAlertActions
        } message: {
            logoutAlertMessage
        }
#else
        NavigationStack {
            settingsForm
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismissAction() }
                        .accessibilityIdentifier("settings-done-button")
                }
            }
        }
        .alert("Logout", isPresented: $showLogoutAlert) {
            logoutAlertActions
        } message: {
            logoutAlertMessage
        }
#endif
    }

    private var settingsForm: some View {
        Form {
            settingsSections
        }
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
                }

                Section(header: Text("Home Page")) {
                    TextField("Home Page", text: $viewModel.homePage)
#if canImport(UIKit)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
#endif
                        .accessibilityIdentifier("home-page-field")
                        .onChange(of: viewModel.homePage) { _, newValue in
                            viewModel.setHomePage(newValue)
                        }
                        .onSubmit {
                            viewModel.qualifyHomePage()
                        }
                }

                Section {
                    StatusButton(text: "Logout",
                                 action: { showLogoutAlert = true },
                                 color: .red)
                        .accessibilityIdentifier("logout-button")
                }

                routingSection
    }

    @ViewBuilder
    private var logoutAlertActions: some View {
        Button("Cancel", role: .cancel) { }
        Button("Logout", role: .destructive) {
            viewModel.logout()
            dismissAction()
        }
    }

    private var logoutAlertMessage: some View {
        Text("This will delete this session, including its tabs, bookmarks, and website data.")
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
