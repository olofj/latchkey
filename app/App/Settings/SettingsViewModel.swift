// Copyright (c) Tailscale Inc & contributors
// SPDX-License-Identifier: BSD-3-Clause

//  SettingsViewModel.swift
//  Latchkey
//
//  Backs the Settings sheet for the ACTIVE workspace. Reads the workspace's
//  hostname/home page from its `WorkspaceDefinition` and writes edits back
//  through the workspace (which persists the definition). Logout is
//  coordinated by WorkspaceManager because it deletes the complete session.
//
//  Latchkey removed the exit-node UI (PLAN §1.8/§7.4): exit nodes and subnet
//  routes are broken under tsnet, because `Dialer.UserDial` takes a plain
//  `net.Dialer` branch for Tailscale routes and, with no TUN, that is a direct
//  dial bypassing WireGuard. Shipping the toggle would ship a known-broken
//  feature, and the egress-IP diagnostic it drove only made sense as its
//  readout. The split-tunnel routing diagnostic below is kept -- it is the
//  on-device ground truth for what is proxied.
//

import Foundation
import Combine
import Network
import TailscaleKit

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var tailnetHostName: String = ""
    @Published var homePage: String = ""

    /// The live split-tunnel rule set: which hosts go through the tsnet SOCKS
    /// proxy vs. load DIRECT. Surfaced in Settings because the device that
    /// showed the `-1000` "invalid URL" bug can't be attached to a Mac (broken
    /// USB port), so `log stream` isn't available — this is the on-device way
    /// to confirm the fix is active and see exactly what is being proxied.
    /// See `TailnetProxyPolicy`.
    var proxyPolicy: TailnetProxyPolicy? { workspace.model.proxyPolicy }

    /// Whether ALL traffic is currently routed through the tailnet proxy rather
    /// than just tailnet destinations.
    ///
    /// With the exit-node feature removed, the ONLY thing that can still set
    /// this is the `-ProxyEverything` launch override, which exists to
    /// demonstrate the `-1000` bug the split tunnel fixes. It cannot be set on
    /// a physical device, so in normal use this is always false.
    var proxyEverything: Bool {
        workspace.model.proxyPolicy?.proxiesEverything ?? TSNetManager.proxyEverythingOverride()
    }

    /// Classifies `host` the way `matchDomains` does — label-wise suffix for
    /// name rules, membership for CIDR rules — so the user can type a host in
    /// Settings and see whether it will be proxied or loaded DIRECT.
    /// Mirrors the semantics verified against a real SOCKS proxy; see the
    /// file comment in `TailnetProxyPolicy.swift`.
    func routeExplanation(for input: String) -> String? {
        let host = TailnetProxyPolicy.normalizeDomain(hostComponent(of: input))
        guard !host.isEmpty else { return nil }
        guard !proxyEverything else {
            return "⚠️ \(host) → PROXY (-ProxyEverything override: all traffic goes through the tailnet)"
        }
        guard let policy = proxyPolicy else {
            return "\(host) → not connected yet (no proxy rules applied)"
        }
        if let rule = policy.matchingRule(for: host) {
            return "\(host) → PROXY via tailnet (matched rule: \(rule))"
        }
        if policy.shortNamesWithheldAsPublicTLD.contains(host) {
            return "\(host) → PROXY after expansion to its tailnet FQDN"
        }
        return "\(host) → DIRECT (not a tailnet host)"
    }

    /// Extracts a bare host from whatever the user typed (a full URL, a
    /// host:port, or just a hostname).
    private func hostComponent(of input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.contains("://"), let h = URL(string: trimmed)?.host() { return h }
        if let h = URL(string: "http://\(trimmed)")?.host() { return h }
        return trimmed
    }

    private let workspace: Workspace
    private let deleteSession: () -> Void
    var workspaceForSettings: Workspace { workspace }
    private var observers: Set<AnyCancellable> = []
    private var homePageNormalizationTask: Task<Void, Never>?

    init(workspace: Workspace,
         deleteSession: @escaping () -> Void) {
        self.workspace = workspace
        self.deleteSession = deleteSession
        // Seed from the workspace's persisted definition + home page.
        self.tailnetHostName = workspace.definition.hostname
        self.homePage = workspace.homePage.url
        observeWorkspace()
    }

    /// Keep the hostname/home-page fields in sync if they change elsewhere
    /// (e.g. the workspace identity refresh, or a future workspace switch).
    private func observeWorkspace() {
        workspace.$definition
            .receive(on: DispatchQueue.main)
            .sink { [weak self] def in
                guard let self else { return }
                if self.tailnetHostName != def.hostname {
                    self.tailnetHostName = def.hostname
                }
            }
            .store(in: &observers)

        workspace.homePage.$url
            .receive(on: DispatchQueue.main)
            .sink { [weak self] url in
                guard let self, self.homePage != url else { return }
                self.homePage = url
            }
            .store(in: &observers)
    }

    func setHomePage(_ url: String) {
        workspace.setHomePage(url)

        // Settings' TextField publishes each keystroke, and relying only on
        // focus/submit callbacks is inconsistent across SwiftUI Form on iOS
        // and macOS. Debounce the same URL-bar normalization so the completed
        // value is qualified automatically after the user pauses typing.
        homePageNormalizationTask?.cancel()
        guard !url.isEmpty else { return }
        homePageNormalizationTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, let self,
                      self.homePage == url else { return }
                self.qualifyHomePage()
            } catch {
                // A subsequent keystroke cancels this task.
            }
        }
    }

    /// Commits the Home Page field using the same normalization as the
    /// browser's URL bar. In particular, `google.com` becomes
    /// `https://google.com`, while a bare tailnet name such as `ai` becomes
    /// `http://ai` and is subsequently qualified using the live tailnet data.
    /// This is intentionally called when editing ends/submission occurs,
    /// rather than on every keystroke, so typing is not disrupted by adding a
    /// scheme after the first character.
    func qualifyHomePage() {
        let trimmed = URLInputNormalizer.trimmed(homePage)
        guard !trimmed.isEmpty else { return }
        homePageNormalizationTask?.cancel()
        let normalized = URLInputNormalizer.normalized(from: trimmed)
        logger.log("Settings: normalized home page \(trimmed) -> \(normalized)")
        if homePage != normalized {
            homePage = normalized
        }
        // Persist directly as well as through the TextField's onChange. This
        // makes normalization reliable even when SwiftUI coalesces the
        // Published update while the Settings sheet is being dismissed.
        workspace.setHomePage(normalized)
    }

    func setTailnetHostName(_ hostName: String) {
        workspace.setHostName(hostName)
    }

    func logout() {
        deleteSession()
    }
}
