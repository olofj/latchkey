// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

//
//  GatewayPickerView.swift
//  Latchkey
//
//  Choose the KiroCrew gateway (PLAN M5.3). Shown instead of the dashboard
//  until a gateway is chosen, and on demand when the chosen one is
//  unreachable (M5.5). Discovered gateways stream in as their probes answer;
//  manual entry is always there, for a gateway discovery cannot see.
//
//  A single gateway found on the first run is chosen without asking: the
//  picker would offer no choice, and signing in happens in the token sheet
//  either way. (M5.3 also asked that it "already has a session"; that cannot
//  be known before loading it, and the answer does not change what to load.)
//

import SwiftUI
import TailscaleKit

struct GatewayPickerView: View {
    @ObservedObject var discovery: GatewayDiscovery
    @ObservedObject var model: TSNetModel
    /// The gateway to probe first (the one already chosen, if any).
    let savedHost: String?
    /// Choose automatically when exactly one gateway is found.
    let autoSelectSingle: Bool
    /// Sweep on appear even if an earlier sweep finished (Find, Settings):
    /// the discovery object outlives the picker, and a stale result -- maybe
    /// the unreachable gateway itself -- is not what Find asked for (M5 review).
    var sweepOnAppear: Bool = false
    /// Called with the gateway's origin, `https://<fqdn>`.
    let onSelect: (String) -> Void
    var onCancel: (() -> Void)?

    @State private var manual = ""
    @State private var manualError: String?
    @State private var autoSelected = false
    @State private var shownAt = ContinuousClock.now

    private var ready: Bool { model.localStatus != nil && model.proxyConfiguration != nil }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if discovery.phase == .probing && discovery.gateways.isEmpty {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Looking for Kiro Crew gateways on your tailnet…")
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityIdentifier("gateway-searching")
                    }
                    ForEach(discovery.gateways) { gateway in
                        Button {
                            onSelect(gateway.url)
                        } label: {
                            Label(gateway.host, systemImage: "server.rack")
                                .font(.body.monospaced())
                        }
                        .accessibilityIdentifier("gateway-\(gateway.host)")
                    }
                    if discovery.phase == .finished && discovery.gateways.isEmpty {
                        Text(discovery.candidateCount == 0
                             ? "No computers on your tailnet could be a gateway. Enter one below."
                             : "No Kiro Crew gateway answered among \(discovery.candidateCount) computer(s) on your tailnet. Enter one below.")
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("gateway-none")
                    }
                    if discovery.phase == .proxyUnhealthy {
                        Text("The tailnet connection isn't passing traffic yet. Search again in a moment.")
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("gateway-proxy-unhealthy")
                    }
                    // In the list, not the toolbar: the dashboard's gear sits
                    // over the navigation bar's trailing corner (M5 review).
                    Button {
                        discovery.start(savedHost: savedHost, shownAt: .now)
                    } label: {
                        Label("Search again", systemImage: "arrow.clockwise")
                    }
                    .disabled(discovery.phase == .probing || !ready)
                    .accessibilityIdentifier("gateway-refresh")
                } header: {
                    Text("Gateways")
                }

                Section {
                    TextField("gateway, or gateway.example.ts.net", text: $manual)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .submitLabel(.go)
                        .onSubmit(useManual)
                        .accessibilityIdentifier("gateway-manual-field")
                    Button("Use this gateway", action: useManual)
                        .disabled(GatewayCandidates.manualOrigin(manual, suffix: suffix) == nil)
                        .accessibilityIdentifier("gateway-manual-use")
                    if let manualError {
                        Text(manualError)
                            .font(.subheadline)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("gateway-manual-error")
                    }
                } header: {
                    Text("Enter manually")
                }
            }
            .accessibilityIdentifier("gateway-picker")
            .navigationTitle("Choose a gateway")
            .toolbar {
                if let onCancel {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", action: onCancel)
                    }
                }
            }
            .overlay(alignment: .bottom) {
                // For UI tests: the sweep's end, and what it found.
                if discovery.phase == .finished || discovery.phase == .proxyUnhealthy {
                    Text("sweep-done:\(discovery.gateways.count)")
                        .accessibilityIdentifier("gateway-sweep-done")
                        .opacity(0.01)
                }
            }
        }
        .onAppear {
            shownAt = .now
            if sweepOnAppear, ready { discovery.start(savedHost: savedHost, shownAt: shownAt) }
        }
        // Start once the node has a status and a proxy to probe through.
        .task(id: ready) {
            if ready, discovery.phase == .idle {
                discovery.start(savedHost: savedHost, shownAt: shownAt)
            }
        }
        // Nothing outlives the picker: a sweep it no longer shows is stopped.
        .onDisappear { discovery.cancel() }
        // A sweep that ran on a status fetched before the peers arrived finds
        // no candidates, and nothing would start another (M5 review): sweep
        // again when the peer list changes after an empty sweep.
        .onChange(of: model.localStatus?.Peer?.count ?? 0) { _, _ in
            if discovery.phase == .finished, discovery.candidateCount == 0 {
                discovery.start(savedHost: savedHost, shownAt: shownAt)
            }
        }
        .onChange(of: discovery.phase) { _, phase in
            guard autoSelectSingle, !autoSelected, phase == .finished,
                  discovery.gateways.count == 1 else { return }
            autoSelected = true
            onSelect(discovery.gateways[0].url)
        }
    }

    private var suffix: String? { model.localStatus?.CurrentTailnet?.MagicDNSSuffix }

    private func useManual() {
        guard let origin = GatewayCandidates.manualOrigin(manual, suffix: suffix) else { return }
        // Only a host the tailnet carries: anything else would load direct,
        // off the tailnet, and become the sign-in origin (M5 review).
        if let host = URL(string: origin)?.host(), let policy = model.proxyPolicy,
           policy.matchingRule(for: host) == nil {
            manualError = "\(host) isn't on your tailnet. Enter the name of a computer on it, like gateway or gateway.<tailnet>.ts.net."
            return
        }
        manualError = nil
        onSelect(origin)
    }

}
