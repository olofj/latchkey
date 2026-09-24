// Copyright (c) Tailscale Inc & contributors
// SPDX-License-Identifier: BSD-3-Clause

//  SettingsViewModel.swift
//  Latchkey
//
//  Backs the Settings sheet for the ACTIVE workspace. Reads the workspace's
//  hostname/home page from its `WorkspaceDefinition` and writes edits back
//  through the workspace (which persists the definition). A reset ends in
//  WorkspaceManager, because it deletes the complete session (R32).
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

    /// Why the last Gateway entry was refused, for the field to show; nil
    /// once an entry is accepted or the field is left alone.
    @Published private(set) var gatewayError: String?

    /// Applies what is in the Gateway field (M5): on Return and when Settings
    /// closes, never per keystroke. Per-keystroke writes let a cleared field
    /// mean "no gateway" and swap the first-run picker in under Settings (M5
    /// review). An empty or unusable entry keeps the current gateway.
    /// Normalized AND checked by the same gate as the picker's manual entry
    /// (`GatewayCandidates.manualGateway`): a bare name is qualified with the
    /// tailnet's suffix, the scheme is always https -- the old URL-bar
    /// normalization produced http://, which ATS now blocks (R28) -- and a
    /// host the tailnet does not carry is refused. Settings once skipped
    /// that check, so a typed public host loaded direct, became the trusted
    /// origin, and would have received a pasted token.
    func commitGateway() {
        let current = workspace.homePage.url
        // An untouched field is not a request; Settings closing must not
        // re-judge the current gateway against a rule set that may be gone.
        guard homePage != current else { gatewayError = nil; return }
        let suffix = workspace.model.localStatus?.CurrentTailnet?.MagicDNSSuffix
        switch GatewayCandidates.manualGateway(homePage, suffix: suffix, policy: workspace.model.proxyPolicy) {
        case .failure(.notAHost):
            // Cleared or unusable: keep the current gateway, quietly.
            homePage = current
        case .failure(let refusal):
            logger.log("Settings: gateway \(LogRedaction.scrub(homePage)) refused: \(refusal)")
            gatewayError = refusal.message
            homePage = current
        case .success(let origin):
            gatewayError = nil
            if homePage != origin { homePage = origin }
            guard origin != current else { return }
            logger.log("Settings: gateway \(LogRedaction.scrub(current)) -> \(origin)")
            workspace.selectGateway(origin)
        }
    }

    /// A gateway chosen in Settings' picker.
    func choose(_ origin: String) {
        homePage = origin
        commitGateway()
    }

    func setTailnetHostName(_ hostName: String) {
        workspace.setHostName(hostName)
    }

    // MARK: - Sign out and reset (R32)

    /// Which of the two is running. Settings stays up with the button
    /// spinning until it is done, then closes: the sign-in sheet waits for
    /// Settings to go (M4), and a reset must not look like a hang while
    /// control is asked to expire the key.
    enum Activity: Equatable {
        case signingOut, resetting
    }
    @Published private(set) var activity: Activity?

    /// Why the reset stopped short of deleting anything: control could not
    /// be asked to expire the node's key (the reason, for the alert). Deleting
    /// regardless would make the orphan permanent -- the key that could still
    /// be expired is in the state that would go (R32 review) -- so Settings
    /// asks: Retry, Delete anyway, or Cancel. Nil once answered.
    @Published var resetBlocked: String?
    /// The dashboard sign-out of the reset in progress, kept for Cancel.
    private var resetSignOut: DashboardSignOut.Outcome?

    /// Sign out of the dashboard: the dashboard session only, on this device
    /// and at the gateway. The node and the gateway choice stay.
    func signOutOfDashboard() async {
        guard activity == nil else { return }
        activity = .signingOut
        _ = await workspace.signOutOfDashboard()
        activity = nil
    }

    /// Reset app: sign out of the dashboard first, while the tailnet is
    /// still up to carry it; then log the node out of Tailscale (its key
    /// expired at the control plane); then delete everything stored here --
    /// node identity, web data, node logs, the gateway choice -- and start
    /// over as on first run. The one way to leave the tailnet: a separate
    /// "log out" that skipped the dashboard step left a live 30-day session
    /// at the gateway (R32 review). Returns with `resetBlocked` set, and
    /// nothing deleted, when the logout failed.
    func resetApp() async {
        guard activity == nil else { return }
        activity = .resetting
        resetSignOut = await workspace.signOutOfDashboard(reload: false)
        await logOutThenFinish()
    }

    /// The alert's Retry: the tailnet logout again. Not the dashboard
    /// sign-out -- its cookies are gone from here already, whatever the
    /// gateway managed.
    func retryReset() async {
        guard activity == nil, resetSignOut != nil else { return }
        activity = .resetting
        await logOutThenFinish()
    }

    /// The alert's Delete anyway: the local state goes although the key is
    /// still valid at control. The node stays in the admin console until it
    /// is removed there (the alert said so).
    func deleteAnyway() {
        guard activity == nil, resetSignOut != nil else { return }
        logger.log("Reset: deleting the node's state without a tailnet logout; it keeps its key at the control plane until removed there")
        finishReset()
    }

    /// The alert's Cancel: the node stays. The dashboard session is already
    /// gone, so the workspace ends up as after a sign-out -- the gateway
    /// loaded afresh, asking for a token.
    func cancelReset() {
        guard activity == nil, let outcome = resetSignOut else { return }
        resetSignOut = nil
        resetBlocked = nil
        logger.log("Reset cancelled after the tailnet logout failed; the node stays")
        workspace.showGatewayAfterSignOut(outcome)
    }

    private func logOutThenFinish() async {
        let outcome = await workspace.logOutOfTailnet()
        activity = nil
        switch outcome {
        case .loggedOut, .noKey, .noNode:
            finishReset()
        case .failed(let reason):
            resetBlocked = reason
        }
    }

    /// Everything stored on this device goes: the node logs here (process-
    /// wide, so not the workspace's to delete; tsnet keeps writing to the
    /// unlinked file until the next launch), then the workspace -- node
    /// state, web data, gateway -- through the manager.
    private func finishReset() {
        resetSignOut = nil
        resetBlocked = nil
        NodeLog.removeFiles(in: WorkspaceStore.logsDir)
        deleteSession()
    }
}
