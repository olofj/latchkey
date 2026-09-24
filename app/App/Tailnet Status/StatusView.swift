// Copyright (c) Tailscale Inc & contributors
// SPDX-License-Identifier: BSD-3-Clause

//
//  StatusViewModel.swift
//  Latchkey
//
//  Created by Jonathan Nobels on 2025-12-16.
//

import SwiftUI

struct StatusView: View {

    @ObservedObject var viewModel: StatusViewModel

    /// Spins the moment the Login button's action fires — a tap acknowledgement
    /// so a human (and a real-device session) can tell whether the tap reached
    /// the button at all. If this spinner NEVER appears, the tap didn't reach
    /// the button (hit-testing / an invisible overlay). If it appears but no
    /// ASWebAuthenticationSession sheet opens, the tap registered and
    /// `showAuth` is hanging (no authURL / bus stuck / sheet failed to
    /// present) — see the logs in `StatusViewModel.showAuth` and
    /// `AuthManager.showAuth` to disambiguate further. Cleared when login
    /// completes (`needsAuth` → false) or after 2 min as a safety so the
    /// button returns to tappable; the spinner persisting that long is itself
    /// the "tap registered but stuck" signal.
    @State private var isStartingLogin = false
    /// When the gate appeared, or when the node's state last changed, whichever
    /// is later (F4 §4.10) — so a node that has been "Connecting…" for a minute
    /// says so, and one that just changed state starts its 15 s afresh.
    @State private var stateSince = ContinuousClock.now

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tailscale Status")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)

            HStack(spacing: 10) {
                Image(systemName: viewModel.statusIconName)
                    .foregroundStyle(iconColor)
                    .imageScale(.large)

                Text(viewModel.statusText)
                    .font(.body)
                    .foregroundStyle(.primary)

                Spacer()
            }

            // G2/G6 (F4 §3.6). "Connecting…" and "Starting…" are unbounded —
            // the node reaches another state when it does — so after 15 s the
            // gate says where to look instead of spinning silently. Three status
            // polls: a node normally gets somewhere inside one.
            if viewModel.isStartingUp {
                StalledHint(since: stateSince, delay: .seconds(15),
                            text: "Still starting after 15 s. Settings → Node log shows what the "
                                + "node is doing.",
                            identifier: "gate-starting-hint")
            } else if viewModel.isStopped {
                Text("Stopped. Latchkey starts the node again when it returns to the "
                     + "foreground; if it doesn't, Settings → Node log.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("gate-stopped-hint")
            }

            if viewModel.needsMachineAuth {
                // First, ahead of loggedInConnecting: a web login ends here
                // when the tailnet requires approval (M3 review). No button:
                // approval happens in the tailnet's admin console, and the
                // node continues by itself once approved.
                Text("This device is logged in but waiting for a tailnet admin to approve it. Approve it in the Tailscale admin console under Machines. Latchkey connects by itself once it is approved.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("needs-machine-auth")
            } else if viewModel.loggedInConnecting {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Finishing the tailnet connection…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("logged-in-connecting")
            } else if viewModel.needsAuth {
                StatusButton(text: "Login",
                             action: {
                    isStartingLogin = true
                    viewModel.showAuth()
                    // Safety: stop spinning after 2 min even if no state
                    // change (sheet never opened), so the button is retryable.
                    Task {
                        try? await Task.sleep(nanoseconds: 120_000_000_000)
                        isStartingLogin = false
                    }
                },
                             isLoading: isStartingLogin)
                    .accessibilityIdentifier("login-button")
            }
        }
        .padding(.vertical, 8)
        .onChange(of: viewModel.needsAuth) { _, needsAuth in
            if !needsAuth { isStartingLogin = false }
        }
        .onChange(of: viewModel.statusText) { _, _ in stateSince = .now }
        .onChange(of: viewModel.authSessionEndedGeneration) { _, _ in
            isStartingLogin = false
        }
    }

    private var iconColor: Color {
        switch viewModel.statusIconName {
        case "checkmark.circle.fill":
            return .green
        case "person.crop.circle.badge.exclamationmark", "clock.badge.exclamationmark":
            return .orange
        case "stop.circle.fill":
            return .red
        case "hourglass.circle.fill":
            return .blue
        default:
            return .secondary
        }
    }
}

struct StatusButton: View {
    let text: String
    let action: () -> Void
    /// Tint for the button — `.borderedProminent` fills the whole button with
    /// it. Defaults to blue (the primary "go" action, e.g. Login). Pass `.red`
    /// for a destructive action (Logout) so it doesn't read as the tempting
    /// default blue button.
    var color: Color = .blue
    /// When true, show a spinner instead of the label (used by Login to
    /// acknowledge the tap instantly while `showAuth` runs).
    var isLoading: Bool = false

    var body: some View {
        Button(action: action) {
            ZStack {
                if isLoading {
                    ProgressView().tint(.white)
                } else {
                    Text(text)
                        .font(.headline)
                }
            }
            // Fill the button's offered width so the whole pill is one
            // tappable element, not just the text.
            .frame(maxWidth: .infinity)
        }
        // Use a standard iOS button style instead of the hand-rolled
        // `.plain` + `RoundedRectangle.background` (which made the hit area
        // the *label's* frame — so only the "Login" text was tappable, not the
        // visible blue button; tapping the button did nothing on a real
        // device). `.borderedProminent` is the full-width filled rounded
        // button this was always trying to look like, and it gives a full-
        // frame hit area + the system's 44pt minimum tap target for free.
        // `.tint(color)` supplies the fill (blue for Login, red for Logout).
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(color)
    }
}