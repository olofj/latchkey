// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

//
//  GatewaySwitcher.swift
//  Latchkey
//
//  F5 §7: Settings' gateway switcher. The page's own instance switcher shows
//  remotes in a plain-HTTP frame on the gateway's loopback, which no phone
//  can reach (F5 §5), so the app switches between what it can load: the
//  gateways this workspace has been switched to, and those a sweep finds.
//
//  A switch is `SettingsViewModel.choose`, the picker's path: the same gate,
//  then `Workspace.selectGateway`. The row's status is a forecast from one
//  sweep, never a gate: a gateway asleep a minute ago may answer now, and F4
//  reports the real load. A host the tailnet does not carry is the one row
//  that cannot be chosen: it would load direct, off the tailnet (M5 review).
//

import SwiftUI

/// What a known gateway's row says. Pure, so the rule is testable on the host.
enum GatewaySwitchStatus: Equatable {
    /// No proxy rule carries the host: choosing it would load it direct.
    case offTailnet
    /// No rule set yet, so nothing can be checked, and nothing is chosen.
    case tailnetNotReady
    case checking
    case answering
    case notAnswering
    /// Every probe failed as if the proxy were down (the picker's own line).
    case proxyUnhealthy
    /// No sweep has run while Settings was up.
    case unchecked

    var text: String {
        switch self {
        case .offTailnet: return "not on this tailnet"
        case .tailnetNotReady: return "the tailnet isn't connected yet"
        case .checking: return "checking…"
        case .answering: return "answering"
        case .notAnswering: return "not answering"
        case .proxyUnhealthy: return "The tailnet connection isn't passing traffic yet"
        case .unchecked: return ""
        }
    }

    var selectable: Bool { self != .offTailnet && self != .tailnetNotReady }

    /// `origin` is an https origin from the known list; `found` is what the
    /// sweep has found so far, as origins.
    static func of(_ origin: String, carried: (String) -> Bool, ready: Bool,
                   phase: GatewayDiscovery.Phase, found: Set<String>) -> Self {
        guard ready else { return .tailnetNotReady }
        guard let host = URL(string: origin)?.host(), carried(host) else { return .offTailnet }
        if found.contains(origin) { return .answering }
        switch phase {
        case .idle: return .unchecked
        case .probing: return .checking
        case .finished: return .notAnswering
        case .proxyUnhealthy: return .proxyUnhealthy
        }
    }
}

/// The rows at the top of Settings → Gateway.
struct GatewaySwitcherRows: View {
    @ObservedObject var viewModel: SettingsViewModel
    @ObservedObject var discovery: GatewayDiscovery
    @ObservedObject var model: TSNetModel
    /// The gateway in use: the workspace's, not the Settings field, which
    /// changes with every keystroke.
    @ObservedObject var homePage: HomePage
    /// Whether the picker is up over Settings: it runs its own sweep on the
    /// same discovery, and cancels it when it goes, so the rows' sweep is
    /// started again then.
    let pickerShown: Bool
    let onSwitch: (String) -> Void

    /// Whether these rows started the sweep in flight, so leaving Settings
    /// cancels only a sweep of its own.
    @State private var sweeping = false

    private var current: String { homePage.url }
    private var others: [String] { viewModel.knownGateways.filter { $0 != current } }
    private var foundOrigins: Set<String> { Set(discovery.gateways.map(\.url)) }
    private var foundNew: [GatewayDiscovery.Gateway] {
        discovery.gateways.filter { $0.url != current && !viewModel.knownGateways.contains($0.url) }
    }

    var body: some View {
        Group {
            if !current.isEmpty {
                HStack {
                    Text(Self.shown(current))
                        .font(.body.monospaced())
                    Spacer()
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Current gateway")
                .accessibilityValue(Self.shown(current))
                .accessibilityIdentifier("gateway-current")
            }
            ForEach(others, id: \.self) { origin in
                row(origin, status: status(origin), id: "gateway-switch-\(Self.shown(origin))")
                    .swipeActions {
                        Button("Forget", role: .destructive) { viewModel.forgetGateway(origin) }
                            .accessibilityIdentifier("gateway-forget-\(Self.shown(origin))")
                    }
            }
            ForEach(foundNew) { gateway in
                row(gateway.url, status: .answering, id: "gateway-found-\(gateway.host)")
            }
        }
        .onAppear(perform: sweepIfUseful)
        .onDisappear {
            if sweeping { discovery.cancel() }
            sweeping = false
        }
        .onChange(of: pickerShown) { _, shown in
            if shown { sweeping = false } else { sweepIfUseful() }
        }
    }

    private func row(_ origin: String, status: GatewaySwitchStatus, id: String) -> some View {
        Button {
            onSwitch(origin)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.shown(origin))
                    .font(.body.monospaced())
                if !status.text.isEmpty {
                    Text(status.text)
                        .font(.caption)
                        .foregroundStyle(status == .answering ? Color.green : Color.secondary)
                }
            }
        }
        // On the Button itself: a wrapping accessibility element would lose
        // its not-enabled trait, and a disabled row would read as tappable.
        .accessibilityLabel(Self.shown(origin))
        .accessibilityValue(status.text)
        .accessibilityIdentifier(id)
        .disabled(!status.selectable)
    }

    private func status(_ origin: String) -> GatewaySwitchStatus {
        GatewaySwitchStatus.of(origin,
                               carried: { model.proxyPolicy?.matchingRule(for: $0) != nil },
                               ready: model.proxyPolicy?.hasPeerData == true,
                               phase: discovery.phase, found: foundOrigins)
    }

    /// One sweep, and only when there is a row to label: with no other known
    /// gateway there is nothing to forecast, and Settings is opened far more
    /// often to do something else. The current gateway is probed first (R26).
    private func sweepIfUseful() {
        guard !pickerShown, !others.isEmpty, model.proxyConfiguration != nil,
              discovery.phase != .probing else { return }
        // Shown now, like the picker: R26's first-result budget holds here too.
        discovery.start(savedHost: URL(string: current)?.host(), shownAt: .now)
        sweeping = true
    }

    /// `host`, or `host:port` (F1's rendering): the origin without its scheme.
    static func shown(_ origin: String) -> String {
        origin.replacingOccurrences(of: "https://", with: "")
    }
}
