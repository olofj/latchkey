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
    @State private var cookies: [String: SessionCookies.Summary]?
    /// Bumped every 2 s: the proxy endpoint and the page's last error are not
    /// observable, so the screen rereads them (and the cookies) on a clock.
    @State private var tick = 0

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
                        LocalCopy.text(sections.map { s in
                            "[\(s.title)]\n" + s.rows.map { "\($0.label): \($0.value)" }.joined(separator: "\n")
                        }.joined(separator: "\n\n"))
                        copied = true
                    }
                    .accessibilityIdentifier("diagnostics-copy-button")
                }
            }
        }
        .accessibilityIdentifier("diagnostics-view")
        .task {
            while !Task.isCancelled {
                let all = await workspace.dataStore.httpCookieStore.allCookies()
                cookies = SessionCookies.summaries(of: all, host: URL(string: homePage.url)?.host() ?? "")
                tick &+= 1
                if copied, tick % 2 == 0 { copied = false }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    // MARK: - Content

    private struct Row { let label: String; let value: String }
    private struct Block { let title: String; let rows: [Row] }

    private var sections: [Block] {
        _ = tick   // reread the unobserved values on the 2-s clock
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
                Row(label: "Key expires", value: keyExpiry.map(Self.date)
                        ?? (me == nil ? "—" : model.state == .Running ? "never (expiry disabled)" : "not known until connected")),
            ]),
            Block(title: "Gateway", rows: [
                Row(label: "Gateway", value: homePage.hasGateway ? homePage.url : "none chosen"),
                Row(label: "In the tailnet", value: availability),
                Row(label: "Last discovery", value: discoverySummary),
            ]),
            Block(title: "Dashboard session", rows: [
                Row(label: "Session", value: session.state.rawValue + (session.isRedeeming ? " (signing in)" : "")),
                Row(label: "Session expires", value: cookies.map { SessionCookies.describe($0, \.refresh, now: Date()) } ?? "reading…"),
                Row(label: "Access expires", value: cookies.map { SessionCookies.describe($0, \.access, now: Date()) } ?? "reading…"),
                Row(label: "Last message", value: session.message ?? "—"),
            ]),
            Block(title: "Proxy", rows: [
                Row(label: "Endpoint", value: workspace.manager.proxyEndpointSummary ?? "not published"),
                Row(label: "Rules", value: (model.proxyPolicy?.matchDomains ?? []).joined(separator: "\n").nonEmpty ?? "none yet"),
                Row(label: "Direct fallback", value: "off (a dead proxy fails the load)"),
                Row(label: "Relay", value: relaySummary),
                Row(label: "Relay restarts", value: "\(counters.socksRelayRestarts)"),
                Row(label: "Relay probes", value: "\(counters.socksRelayProbes) (\(counters.socksRelayProbesFailed) found it dead)"),
            ]),
            Block(title: "Page", rows: [
                // F4 §4.11. "Last error" was the only thing here, and it was
                // whatever string the overlay happened to be showing; the state
                // says what the page is doing NOW, which is what someone reading
                // this on a device without a Mac needs. Read-only, and nothing
                // leaves the device (D1).
                Row(label: "State", value: pageStateSummary),
                Row(label: "Last error", value: lastPageErrorSummary),
                Row(label: "Last proxy reply", value: lastProxyReplySummary),
                Row(label: "Web page restarts", value: "\(counters.webContentTerminations) (\(counters.webContentAutoReloads) reloaded)"),
            ]),
            Block(title: "App", rows: [
                Row(label: "Version", value: Self.version),
                Row(label: "Commit", value: Self.gitSHA),
                Row(label: "Build", value: Self.configuration),
                Row(label: "Profile expires", value: profile.map(Self.date)
                        ?? (Self.profileURL == nil ? "no profile (simulator or App Store build)" : "profile unreadable")),
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

    /// Whether WebKit talks to the logging relay or to tsnet directly, and
    /// why (R30 review): a relay that never started, or lost its listener
    /// for good, leaves the log without per-connection lines.
    private var relaySummary: String {
        guard SocksLogProxy.isEnabled() else { return "off (-NoSocksLog)" }
        if counters.socksRelayFallbacks > 0 {
            return "bypassed: no listener could be started (\(counters.socksRelayFallbacks)×)"
        }
        return "on"
    }

    private var pageStateSummary: String {
        guard let vm = workspace.tabManager.currentTab?.viewModel else { return "no page" }
        return PageFailureText.describe(vm.pageState)
    }

    /// The failure's own cause sentence, not whatever string the overlay is
    /// showing: the two were the same before F4 and are not now.
    private var lastPageErrorSummary: String {
        guard let vm = workspace.tabManager.currentTab?.viewModel else { return "none" }
        if case .failed(let f) = vm.pageState {
            return PageFailureText.lines(for: f).cause
        }
        return vm.navErrorMessage ?? "none"
    }

    /// The last CONNECT the tailnet proxy refused. The only place the SOCKS
    /// reply code survives: WebKit turns every one of them into -1000.
    private var lastProxyReplySummary: String {
        guard let r = model.lastProxyFailure else { return "none" }
        return "\(r.target): \(r.reply) after \(PageState.milliseconds(r.elapsed)) ms"
    }

    private var discoverySummary: String {
        switch discovery.phase {
        case .idle: return "not run"
        case .probing:
            return "probing \(discovery.probedCount) of \(discovery.candidateCount)…"
        case .finished:
            // The last sweep's own numbers (F4 §4.8), and whether it finished.
            // "1 of 4 candidates" alone said nothing about a sweep that ran out
            // of time, which on a large tailnet is most of them (F7).
            guard let s = discovery.lastSweep else {
                return "\(discovery.gateways.count) of \(discovery.candidateCount) candidate(s)"
            }
            let took = String(format: "%.1f s", Double(PageState.milliseconds(s.elapsed)) / 1000)
            let probed = s.truncated ? "\(s.probed) of \(s.candidates)" : "all \(s.candidates)"
            return "\(s.gateways) found; checked \(probed), \(s.answered) answered, "
                + "\(s.unanswered) didn't, \(took)"
                + (s.truncated ? " (ran out of time)" : "")
        case .proxyUnhealthy: return "proxy not answering"
        }
    }

    // MARK: - Static facts

    static let profileURL = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision")

    static let profileExpiry: Date? = {
        guard let url = profileURL, let data = try? Data(contentsOf: url) else { return nil }
        return Expiry.profileExpiration(data)
    }()

    static var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    /// The commit the build was made from, `-dirty` if `make tf UPLOAD=0`
    /// exported an uncommitted tree (F12). A build without the setting --
    /// Xcode's Run, or anything from before F12 -- carries an empty value.
    static var gitSHA: String {
        (Bundle.main.object(forInfoDictionaryKey: "LatchkeyGitSHA") as? String)?.nonEmpty ?? "—"
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
