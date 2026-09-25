// Copyright (c) Tailscale Inc & contributors
// SPDX-License-Identifier: BSD-3-Clause

//
//  ConnectionGateView.swift
//  Latchkey
//
//  The pre-connection "onboarding" screen: the brand header + Tailscale status
//  + Sign in button. Shown by `DashboardRootView` until the tailnet first
//  reaches `Running`, after which the dashboard takes over for the rest of
//  the session. Keeps the brand header (with the Settings gear) and the
//  "Tailscale Status" section so the connection-independent UI tests still
//  have their anchors here.
//
//  F11: before the node has ever been logged in, an introduction sits above
//  the status — what the app is, why Tailscale, and the steps after sign-in.
//  The words scroll; the sign-in button does not. It is pinned below the
//  scrolling content, so no amount of copy, at any Dynamic Type size, can
//  push the screen's only control off it (F11 §4.3).
//

import SwiftUI

struct ConnectionGateView: View {
    @ObservedObject var statusViewModel: StatusViewModel
    /// The workspace's `hasEverConnected` (F11 §4.2): the introduction is for
    /// an install that has never been logged in, not for a returning user
    /// whose key expired.
    let hasEverConnected: Bool
    let onSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            LatchkeyBrandHeader {
                HStack(spacing: 14) {
                    Button {
                        onSettings()
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 18))
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("settings-button")
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if statusViewModel.needsAuth && !hasEverConnected {
                        GateIntroduction()
                    }
                    StatusView(viewModel: statusViewModel)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Outside the ScrollView, deliberately (F11 §4.3). The same
            // precedence StatusView gives its hints: approval and "logged in,
            // connecting" both mean there is nothing to sign in to.
            if statusViewModel.needsAuth && !statusViewModel.needsMachineAuth
                && !statusViewModel.loggedInConnecting {
                GateLoginButton(viewModel: statusViewModel)
                    .padding(.horizontal)
                    .padding(.vertical, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.platformSystemBackground)
#if LATCHKEY_TEST_HOOKS && canImport(UIKit)
        // F11 §6: the window's safe area, so L1 can check the pinned button
        // is inside it. They read the window; where they sit does not matter.
        .overlay(alignment: .topLeading) {
            if TestHooks.flag("-UITestReportSafeArea") {
                VStack(spacing: 0) {
                    WindowSafeAreaProbe(edge: .top).frame(width: 1, height: 1)
                    WindowSafeAreaProbe(edge: .bottom).frame(width: 1, height: 1)
                }
                .opacity(0.01)
                .allowsHitTesting(false)
            }
        }
#endif
    }
}

/// What Latchkey is and what signing in will lead to (F11 §2). A fresh
/// install is a new node on the tailnet: it may need approval and signing,
/// and it needs a grant to the dashboard's machine. Said here, before the
/// button, those are steps in a list rather than "scan found nothing".
///
/// Copy is written into the view: the app is not localised (F11 §4.4).
struct GateIntroduction: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Latchkey opens one thing: the KiroCrew dashboard running on a machine you own. It is not a general web browser.")
            Text("That machine is not on the public internet, so Latchkey carries its own Tailscale node to reach it directly. No VPN profile is installed, the rest of this phone's traffic is untouched, and Latchkey's logs stay on this device.")

            Text("What happens next")
                .font(.headline)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(Self.steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1).")
                            .monospacedDigit()
                        Text(step)
                    }
                }
            }
            // One element, so the list reads as a list to VoiceOver and the
            // tests can read the steps as one text.
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("gate-intro-steps")
        }
        .font(.body)
        .foregroundStyle(.primary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("gate-intro")
    }

    /// F11 §2.3. The grant step reads directly, with no conditional: settled
    /// 2026-09-24 (F11 §8) — revisit if Latchkey is used on a tailnet the
    /// user does not administer.
    static let steps = [
        "Sign in to your tailnet in a browser sheet.",
        "This install is a new device, so your tailnet may need to approve it — and sign it, if you use tailnet lock.",
        "It needs access to the machine running the dashboard.",
        "Then Latchkey finds the dashboard and opens it.",
    ]
}
