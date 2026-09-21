// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

//
//  DiagnosticsView.swift
//  Latchkey
//
//  Everything needed to debug a failure without a Mac (PLAN M8.2, revision
//  R29): the node, the gateway, the dashboard session, the proxy, the last
//  page error, and the two clocks that end the app (R31, R33). Built before
//  M6's device tests, which read it afterwards.
//
//  Nothing secret is shown: the proxy's credential is never read here, the
//  session cookies are reduced to their expiry dates (SessionCookies), and
//  "Copy" copies exactly what is on screen.
//

import SwiftUI
import TailscaleKit
import WebKit
#if canImport(UIKit)
import UIKit
#endif

struct DiagnosticsView: View {
    let workspace: Workspace
    @ObservedObject var model: TSNetModel
    @ObservedObject var session: SessionManager
    @ObservedObject var discovery: GatewayDiscovery
    @ObservedObject var homePage: HomePage
    @ObservedObject private var counters = AppDiagnostics.shared
    var dismissAction: () -> Void
    @State private var copied = false
    /// Expiry dates only: the cookies themselves are not kept.
    @State private var cookies: SessionCookies.Summary?

    var body: some View {
        NavigationStack {
            List {
                ForEach(sections, id: \.title) { section in
                    Section(section.title) {
                        ForEach(section.rows, id: \.label) { row in
                            LabeledContent(row.label) {
                                Text(row.value)
                                    .font(.subheadline.monospaced())
                                    .multilineTextAlignment(.trailing)
                                    .textSelection(.enabled)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("diag-\(row.label.lowercased().replacingOccurrences(of: " ", with: "-"))")
                        }
                    }
                }
            }
            .accessibilityIdentifier("diagnostics-list")
            .navigationTitle("Status")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", action: dismissAction)
                        .accessibilityIdentifier("diagnostics-done-button")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(copied ? "Copied" : "Copy") {
                        UIPasteboard.general.string = sections.map { s in
                            "[\(s.title)]\n" + s.rows.map { "\($0.label): \($0.value)" }.joined(separator: "\n")
                        }.joined(separator: "\n\n")
                        copied = true
                    }
                }
            }
        }
        .accessibilityIdentifier("diagnostics-view")
        .task {
            let all = await workspace.dataStore.httpCookieStore.allCookies()
            cookies = SessionCookies.summary(of: all, host: URL(string: homePage.url)?.host() ?? "")
        }
    }

    // MARK: - Content

    private struct Row { let label: String; let value: String }
    private struct Block { let title: String; let rows: [Row] }

    private var sections: [Block] {
        let status = model.localStatus
        let me = status?.SelfStatus
        let keyExpiry = Expiry.parseKeyExpiry(me?.KeyExpiry)
        let profile = Self.profileExpiry
        let warnings = Expiry.warnings(keyExpiry: keyExpiry, profileExpiry: profile, now: Date())
        return [
            Block(title: "Node", rows: [
                Row(label: "State", value: model.state.map { "\($0)" } ?? "starting"),
                Row(label: "Name", value: workspace.definition.hostname),
                Row(label: "Tailnet", value: status?.CurrentTailnet?.MagicDNSSuffix ?? "—"),
                Row(label: "Addresses", value: (status?.TailscaleIPs ?? []).map { "\($0)" }.joined(separator: "\n").nonEmpty ?? "—"),
                Row(label: "Peers", value: "\(status?.Peer?.count ?? 0)"),
                Row(label: "Key expires", value: keyExpiry.map(Self.date) ?? (me == nil ? "—" : "never (expiry disabled)")),
            ]),
            Block(title: "Gateway", rows: [
                Row(label: "Gateway", value: homePage.hasGateway ? homePage.url : "none chosen"),
                Row(label: "In the tailnet", value: availability),
                Row(label: "Last discovery", value: discoverySummary),
            ]),
            Block(title: "Dashboard session", rows: [
                Row(label: "Session", value: session.state.rawValue + (session.isRedeeming ? " (signing in)" : "")),
                Row(label: "Session expires", value: cookies.map { SessionCookies.describe($0.refresh, now: Date()) } ?? "reading…"),
                Row(label: "Access expires", value: cookies.map { SessionCookies.describe($0.access, now: Date()) } ?? "reading…"),
                Row(label: "Last message", value: session.message ?? "—"),
            ]),
            Block(title: "Proxy", rows: [
                Row(label: "Endpoint", value: workspace.manager.proxyEndpointSummary ?? "not published"),
                Row(label: "Rules", value: (model.proxyPolicy?.matchDomains ?? []).joined(separator: "\n").nonEmpty ?? "none yet"),
                Row(label: "Direct fallback", value: "off (a dead proxy fails the load)"),
            ]),
            Block(title: "Page", rows: [
                Row(label: "Last error", value: workspace.tabManager.currentTab?.viewModel.navErrorMessage ?? "none"),
                Row(label: "Web page restarts", value: "\(counters.webContentTerminations) (\(counters.webContentAutoReloads) reloaded)"),
            ]),
            Block(title: "App", rows: [
                Row(label: "Version", value: Self.version),
                Row(label: "Build", value: Self.configuration),
                Row(label: "Profile expires", value: profile.map(Self.date) ?? "no profile (simulator)"),
                Row(label: "Warnings", value: warnings.map(Expiry.message).joined(separator: "\n").nonEmpty ?? "none"),
            ]),
        ]
    }

    private var availability: String {
        guard homePage.hasGateway else { return "—" }
        switch HomePageAvailabilityChecker.check(urlString: homePage.url, status: model.localStatus) {
        case .available: return "yes"
        case .unavailable: return "no"
        case .checking: return "checking"
        }
    }

    private var discoverySummary: String {
        switch discovery.phase {
        case .idle: return "not run"
        case .probing: return "probing \(discovery.candidateCount)…"
        case .finished: return "\(discovery.gateways.count) of \(discovery.candidateCount) candidate(s)"
        case .proxyUnhealthy: return "proxy not answering"
        }
    }

    // MARK: - Static facts

    static let profileExpiry: Date? = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else { return nil }
        return Expiry.profileExpiration(data)
    }()

    static var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    static var configuration: String {
#if LATCHKEY_TEST_HOOKS
        "Testing (test hooks compiled in)"
#elseif DEBUG
        "Debug"
#else
        "Release"
#endif
    }

    static func date(_ d: Date) -> String {
        d.formatted(date: .abbreviated, time: .shortened)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
