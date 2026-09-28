// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

//
//  GatewayRow.swift
//  Latchkey
//
//  F22: the app bar's row of gateways. One chip per remembered gateway, the
//  one in use first, each with the dashboard's instance-bar light; one tap
//  on another switches to it directly. The dashboard's own instance bar
//  cannot do this from a phone: its remotes are plain-HTTP frames on the
//  gateway's loopback (F5 §5). These are gateways the app itself opens.
//
//  It lives in the bar, so it is there only when the bar is (F15): nothing
//  of it is on the page, and it adds no height.
//

import SwiftUI

struct GatewayRow: View {
    /// In order, in use first (`GatewayChipState.order`); never empty.
    let origins: [String]
    let current: String
    /// The page in use: its load is the in-use chip's light.
    @ObservedObject var page: BrowserViewModel
    /// The node: whether it has a rule set yet, and which hosts it carries.
    @ObservedObject var tsnet: TSNetModel
    @ObservedObject var health: GatewayHealth
    let onSwitch: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(origins, id: \.self) { origin in
                    GatewayChip(origin: origin, inUse: origin == current, state: state(origin)) {
                        onSwitch(origin)
                    }
                }
            }
            .padding(.horizontal, 2)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("gateway-row")
        // Probes only while the row is on screen, and again every
        // `freshFor` while it stays (F22 §4). Started again when the tailnet
        // becomes ready: the row is often up before the node is, and a
        // refresh then can probe nothing.
        .task(id: Probing(origins: others, ready: ready)) {
            while !Task.isCancelled {
                health.refresh(others)
                try? await Task.sleep(for: GatewayHealth.freshFor)
            }
        }
        .onDisappear { health.stop() }
    }

    private var others: [String] { origins.filter { $0 != current } }

    private var ready: Bool {
        tsnet.proxyConfiguration != nil && tsnet.proxyPolicy?.hasPeerData == true
    }

    private struct Probing: Equatable {
        let origins: [String]
        let ready: Bool
    }

    private func state(_ origin: String) -> GatewayChipState {
        if origin == current { return .current(Self.load(page.pageState)) }
        let host = URL(string: origin)?.host() ?? ""
        let policy = tsnet.proxyPolicy
        return .other(ready: policy?.hasPeerData == true,
                      carried: !host.isEmpty && policy?.matchingRule(for: host) != nil,
                      verdict: health.verdicts[origin])
    }

    static func load(_ state: PageState) -> GatewayChipState.Load {
        switch state {
        case .idle: return .idle
        case .holding, .connecting: return .connecting
        case .committed: return .committed
        case .failed: return .failed
        }
    }
}

/// One chip: the dashboard's `e8`, in SwiftUI. A bordered 26 pt capsule-ish
/// button, 12 pt text and a 6 pt light; the one in use filled and bold.
private struct GatewayChip: View {
    let origin: String
    let inUse: Bool
    let state: GatewayChipState
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Circle()
                    .fill(Self.color(state.light))
                    .frame(width: 6, height: 6)
                Text(GatewayChipState.shortName(origin))
                    .font(.system(size: 12, weight: inUse ? .bold : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 140, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
                if !state.word.isEmpty && state.light != .ok {
                    Text(state.word)
                        .font(.system(size: 11))
                        .foregroundStyle(state.light == .muted ? Color.secondary : Self.color(state.light))
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .foregroundStyle(inUse ? Color.accentColor : Color.primary)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(inUse ? Color.accentColor.opacity(0.15) : Color.clear)
            }
            .overlay {
                if !inUse {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.secondary.opacity(0.35), lineWidth: 1)
                }
            }
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The chip in use is not a switch, and a gateway off the tailnet may
        // not be chosen at all; the dimmed look is the not-enabled trait.
        .disabled(!state.tappable)
        .opacity(!state.tappable && !inUse ? 0.6 : 1)
        .accessibilityLabel(GatewayChipState.shown(origin) + (inUse ? ", in use" : ""))
        .accessibilityValue(state.word)
        .accessibilityIdentifier("gateway-chip-\(GatewayChipState.shown(origin))")
    }

    /// KiroCrew's `--ok`, `--warn`, `--danger` and `--muted`, as the system's
    /// own green, orange, red and grey, which adapt to light and dark.
    static func color(_ light: GatewayChipState.Light) -> Color {
        switch light {
        case .ok: return .green
        case .warn: return .orange
        case .danger: return .red
        case .muted: return .gray
        }
    }
}
