// Copyright (c) Tailscale Inc & contributors
// SPDX-License-Identifier: BSD-3-Clause

//  Workspace.swift
//  Latchkey
//
//  A workspace = one Tailscale (tsnet) identity + everything that belongs to
//  it: its own node, model, tab manager, home page, bookmarks store, and web
//  data store. All workspaces are live concurrently (each runs its own
//  `TailscaleNode`; the node docs allow several per app, each gets its own
//  tailnet IP). Switching the "active" workspace (Phase 3) just changes which
//  one's tabs/home page the browser pane shows — nothing is torn down.
//
//  This bundles what used to be process-wide singletons (one `TSNetManager`,
//  one shared `WKWebsiteDataStore`, one global `HomePage`, one global SwiftData
//  container) into a per-identity object owned by `WorkspaceManager`.
//

import Combine
import SwiftUI
import WebKit
import TailscaleKit

@MainActor
final class Workspace: ObservableObject, Identifiable {
    let id: UUID

    /// The persisted definition. `@Published` so Settings (hostname/home page)
    /// and the workspace identifier react to edits. Mutations are written back
    /// to disk via `onChange` (set by `WorkspaceManager`).
    @Published private(set) var definition: WorkspaceDefinition

    /// Last-known Tailscale identity, persisted in the definition so the
    /// identifier renders immediately on the next launch (before the node
    /// reconnects), then live-updated from the netmap/prefs while connected.
    @Published private(set) var identity: WorkspaceIdentity

    let manager: TSNetManager
    var model: TSNetModel { manager.model }

    let homePage: HomePage
    /// Per-workspace web data store (isolated cookies/cache/service workers +
    /// the SOCKS5 proxy is applied here, in place, on reconnect).
    let dataStore: WKWebsiteDataStore

    /// The dashboard session: sign-in state and the token sheet (M4).
    let session = SessionManager()

    /// Browser/session state is lazy so its first WKWebView is still created
    /// from `WorkspaceRoot.init`, after a window exists. Unlike a view-local
    /// StateObject, workspace ownership keeps tabs alive while another account
    /// is selected.
    lazy var tabManager = TabManager(workspaceID: id,
                                     model: model,
                                     homePage: homePage,
                                     dataStore: dataStore,
                                     session: session,
                                     // A load that failed on transport goes to the
                                     // manager, which may restart its relay (R30).
                                     reportLoadFailure: { [manager] in manager.pageLoadFailed($0) },
                                     allowWidgetCDNs: { [weak self] in self?.definition.widgetCDNsAllowed ?? true })
    lazy var statusViewModel: StatusViewModel = {
        let vm = StatusViewModel(manager: manager)
        // F8 §4.4: the move is the workspace's, since it names the directory.
        vm.startNewNode = { [id, manager] in
            try await manager.startNewNode { try WorkspaceStore.setStateDirAside(id) }
        }
        return vm
    }()
    /// Finds KiroCrew gateways on this workspace's tailnet (M5).
    lazy var discovery = GatewayDiscovery(model: model) { [manager] in
        await manager.refreshStatusNow()
    }

    /// Called whenever the definition changes, so `WorkspaceManager` can
    /// persist the workspace list. Set after init to avoid a retain cycle.
    var onChange: ((WorkspaceDefinition) -> Void)?

    private var cancellables: Set<AnyCancellable> = []
    private var profileRefreshInFlight = false

    /// - Parameters:
    ///   - definition: The persisted definition (hostname, home page, etc.).
    ///   - authKey: The shared launch-arg auth key (tests), or nil for a
    ///     workspace that authenticates via web auth. NOT stored in the
    ///     definition — it lives only in the live `Configuration`.
    ///   - onChange: Persist-on-change callback (set by `WorkspaceManager`).
    init(definition: WorkspaceDefinition, authKey: String?,
         onChange: ((WorkspaceDefinition) -> Void)? = nil) {
        self.id = definition.id
        self.definition = definition
        self.identity = definition.lastKnownIdentity
            ?? WorkspaceIdentity(hostname: definition.hostname)
        self.onChange = onChange

        // A test launch may point the node at the L2 harness's control plane
        // (R17). Never written back into the definition.
        let config = Configuration(hostName: definition.hostname,
                                    path: WorkspaceStore.stateDir(definition.id).path,
                                    authKey: authKey,
                                    controlURL: TestControlPlane.controlURLOverride()
                                        ?? definition.controlURL,
                                    ephemeral: definition.ephemeral)
        self.manager = TSNetManager(config: config)

        // Reduce whatever was stored to something that cannot carry a
        // credential (R2). A build before R2 could have persisted a pasted
        // sign-in URL here; the observer below writes the cleaned value back.
        self.homePage = HomePage(url: GatewayAddress.persistable(definition.homePageURL))
        self.dataStore = WKWebsiteDataStore(forIdentifier: definition.dataStoreUUID)

        // A session check the page could not answer twice is the manager's
        // cue to probe its relay listener (R30 review).
        let manager = self.manager
        session.onUnansweredCheck = { manager.sessionCheckUnanswered() }

        // Persist home-page edits back into the definition.
        homePage.$url
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] url in
                // Never a query or fragment on disk (R2), whatever set it.
                let url = GatewayAddress.stripParameters(url)
                guard let self, self.definition.homePageURL != url else { return }
                self.definition.homePageURL = url
                self.onChange?(self.definition)
            }
            .store(in: &cancellables)

        // Live-update the identity from the netmap + prefs (tailnet name, user
        // profile, hostname) and persist it so it's available immediately on
        // the next launch. Handles hostname changes made in the admin console
        // or via Settings while connected.
        manager.model.$netmap
            .combineLatest(manager.model.$prefs)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in self?.refreshIdentity() }
            .store(in: &cancellables)

        // Tagged/auth-key nodes can have incomplete user data in the decoded
        // netmap. The local profile endpoint carries the authoritative login
        // username, so fold it into the persisted identifier after status is
        // available.
        manager.model.$localStatus
            .compactMap { $0 }
            .prefix(while: { [weak self] _ in self?.identity.loginName?.isEmpty != false })
            .sink { [weak self] _ in self?.refreshLoginProfile() }
            .store(in: &cancellables)

        // F11 §4.2: the first `Running` is what retires the connection gate's
        // introduction for good. Written once; never cleared.
        manager.model.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self, state == .Running, !self.definition.hasEverConnected else { return }
                self.definition.hasEverConnected = true
                self.onChange?(self.definition)
            }
            .store(in: &cancellables)
    }

    // MARK: - Lifecycle (forwarded to the per-workspace tsnet controller)

    func willEnterBackground() { manager.willEnterBackground() }
    func willEnterForeground() { manager.willEnterForeground() }

    // MARK: - Settings actions

    func setHostName(_ newHostName: String) {
        let trimmed = newHostName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        definition.hostname = trimmed
        onChange?(definition)
        manager.setHostName(trimmed)
    }

    /// Makes `origin` the gateway and loads it (M5).
    func selectGateway(_ origin: String) {
        logger.log("Gateway chosen: \(origin)")
        // F5 §7: remembered for Settings' switcher, most recent first.
        definition.rememberGateway(origin)
        onChange?(definition)
        setHomePage(origin)
        // The old gateway's sign-in state means nothing for the new one.
        session.reset()
        tabManager.reopenHomeTab()
    }

    /// F5 §7: takes a gateway off the switcher's list. The current one stays
    /// the gateway; it is simply not remembered until chosen again.
    func forgetGateway(_ origin: String) {
        logger.log("Gateway forgotten: \(origin)")
        definition.forgetGateway(origin)
        onChange?(definition)
    }

    /// F6 §4.1a: *Allow widget CDNs*. The page is reopened, so the next load
    /// installs the list compiled for the new setting; the list for the old
    /// one stays cached under its own identifier and is not reused.
    func setAllowWidgetCDNs(_ allowed: Bool) {
        guard definition.widgetCDNsAllowed != allowed else { return }
        logger.log("Settings: widget CDNs \(allowed ? "allowed" : "blocked")")
        definition.allowWidgetCDNs = allowed
        onChange?(definition)
        tabManager.reopenHomeTab()
    }

    func setHomePage(_ url: String) {
        // Called on every keystroke of the Settings field, where a pasted
        // sign-in URL is the natural input. Cut its parameters before they can
        // reach the definition (R2); the committed value is reduced to an
        // origin by SettingsViewModel.qualifyHomePage.
        homePage.url = GatewayAddress.stripParameters(url)   // observer persists
    }

    // MARK: - Sign out and reset (R32)

    /// Ends the dashboard session. The gateway is asked to revoke it as the
    /// page (DashboardSignOut: only a page-world POST carries the refresh
    /// cookie and the Origin its CSRF check wants); then this workspace's web
    /// data -- cookies, storage, caches -- is cleared whatever the gateway
    /// said; then the gateway is loaded afresh, so its page asks for a token
    /// again and the native sheet appears (M4). The node and the gateway
    /// choice are untouched. `reload` false when the workspace is about to
    /// be deleted anyway (reset).
    func signOutOfDashboard(reload: Bool = true) async -> DashboardSignOut.Outcome {
        let outcome = DashboardSignOut.outcome(logoutStatus: await session.requestLogout())
        // No page may set a cookie between the wipe and the fresh load: the
        // page is stopped first, then released.
        await blankCurrentPage()
        tabManager.unloadAllWebViews()
        await dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                                   modifiedSince: .distantPast)
        logger.log("Sign out: \(outcome); web data cleared")
        if reload { showGatewayAfterSignOut(outcome) }
        return outcome
    }

    /// The end of a sign-out that keeps this workspace: the gateway loaded
    /// afresh, so its page asks for a token again and the native sheet
    /// appears (M4), saying what the sign-out managed. Also where a reset
    /// that stopped at the tailnet logout and was cancelled ends up (R32
    /// review): the dashboard session is gone by then, the node stays.
    func showGatewayAfterSignOut(_ outcome: DashboardSignOut.Outcome) {
        session.reset(notice: DashboardSignOut.notice(for: outcome))
        tabManager.reopenHomeTab()
    }

    /// Navigates the page to about:blank and waits for the commit. Unloading
    /// alone does not stop a page (R32 review): the WKWebView stays in the
    /// view hierarchy, its scripts keep running, and `RawWebView.updateUIView`
    /// re-attaches it, so the gateway's page could set a cookie between the
    /// wipe and the fresh load. A committed about:blank has no script left
    /// to do that. Bounded: a page that will not commit is left to the wipe.
    private func blankCurrentPage() async {
        guard let tab = tabManager.currentTab, tab.hasWebView else { return }
        let blank = URL(string: "about:blank")!
        guard tab.viewModel.url != blank else { return }
        tab.viewModel.load(url: blank)
        let deadline = ContinuousClock.now + .seconds(3)
        while tab.viewModel.url != blank, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if tab.viewModel.url != blank {
            logger.log("Sign out: the page did not commit about:blank in time; releasing it as it is")
        }
    }

    /// Logs the node out of the tailnet (TailnetLogout): control expires its
    /// key first, so that deleting the local state afterwards leaves no node
    /// with a valid key behind (R32). Bounded. On `.failed` the caller must
    /// NOT delete the local state: the key that could still be expired is in
    /// it (R32 review).
    func logOutOfTailnet() async -> TailnetLogout.Outcome {
        guard let node = manager.node else {
            logger.log("Tailnet logout: no node to log out")
            return .noNode
        }
        // Whether control holds a key this can expire: a node past
        // NeedsLogin. At NeedsLogin (never logged in, or the key already
        // expired) LocalAPI still answers 204, with nothing to orphan.
        let state = model.state
        let hadKey = state.map { [.NeedsMachineAuth, .Starting, .Running, .Stopped].contains($0) } ?? false
        do {
            // The session TailscaleKit's own LocalAPI calls use (ephemeral;
            // R29 review), and the loopback they are addressed to.
            let (config, loopback) = try await URLSessionConfiguration.tailscaleSession(node)
            guard let ip = loopback.ip, let port = loopback.port,
                  let request = TailnetLogout.request(ip: ip, port: port, localAPIKey: loopback.localAPIKey)
            else {
                logger.log("Tailnet logout: no loopback address; the node keeps its key at the control plane")
                return .failed("no loopback address")
            }
            let urlSession = URLSession(configuration: config)
            defer { urlSession.finishTasksAndInvalidate() }
            let (_, response) = try await urlSession.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let outcome = TailnetLogout.outcome(status: status, hadKey: hadKey)
            switch outcome {
            case .loggedOut:
                logger.log("Tailnet logout: LocalAPI answered \(status); the node's key is expired at the control plane and its profile is gone here")
            case .noKey:
                logger.log("Tailnet logout: LocalAPI answered \(status); the node was at \(state.map { "\($0)" } ?? "no state") with no valid key, so there was nothing at the control plane to expire")
            case .failed, .noNode:
                logger.log("Tailnet logout: LocalAPI answered \(status); the node keeps its key at the control plane")
            }
            return outcome
        } catch {
            let reason = LogRedaction.describe(error)
            logger.log("Tailnet logout failed: \(reason); the node keeps its key at the control plane")
            return .failed(reason)
        }
    }

    /// Stops this workspace and removes all session-owned data. The manager
    /// has already removed it from the published workspace list before calling
    /// this, so no new work can start against these stores.
    func deleteSessionData() async {
        tabManager.unloadAllWebViews()
        await manager.shutdown()

        let dataStoreID = definition.dataStoreUUID
        await dataStore.removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: .distantPast
        )
        do {
            // This removes the named store itself when WebKit has released the
            // last page process; the content wipe above is the privacy-critical
            // fallback if WebKit is still winding one down.
            try await WKWebsiteDataStore.remove(forIdentifier: dataStoreID)
        } catch {
            logger.log("Delete session: web data was cleared, but its empty store could not be removed \(dataStoreID): \(error)")
        }
        WorkspaceStore.removeWorkspaceDir(id)
        logger.log("Delete session: removed workspace \(id)")
    }

    // MARK: - Identity

    /// Human-readable workspace identifier: `login · tailnet · hostname` once
    /// known, degrading to the display name (then hostname) before connect.
    var identifier: String {
        var parts: [String] = []
        if let ln = identity.loginName, !ln.isEmpty { parts.append(ln) }
        if let tn = identity.tailnetName, !tn.isEmpty { parts.append(tn) }
        if let h = identity.hostname, !h.isEmpty { parts.append(h) }
        if !parts.isEmpty { return parts.joined(separator: " · ") }
        return definition.displayName.isEmpty ? definition.hostname : definition.displayName
    }

    private func refreshLoginProfile() {
        guard !profileRefreshInFlight else { return }
        profileRefreshInFlight = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.profileRefreshInFlight = false }
            guard let profile = try? await manager.localAPIClient?.currentProfile() else { return }
            var updated = identity
            let login = profile.UserProfile.LoginName
            let display = profile.UserProfile.DisplayName
            if !login.isEmpty { updated.loginName = login }
            if !display.isEmpty { updated.displayName = display }
            if let domain = profile.NetworkProfile?.DomainName, !domain.isEmpty {
                updated.tailnetName = domain
            }
            persistIdentity(updated)
        }
    }

    private func refreshIdentity() {
        let nm = model.netmap
        let prefs = model.prefs
        let tailnetName = nm?.Domain ?? identity.tailnetName
        let profile = nm?.currentUserProfile()
        let loginName = profile?.LoginName ?? identity.loginName
        let displayName = profile?.DisplayName ?? identity.displayName
        // Prefer the configured hostname from prefs (it's what setHostName
        // edits), then the netmap self node, then the definition's hostname.
        let hostname = (prefs?.Hostname.isEmpty == false ? prefs?.Hostname : nil)
            ?? nm?.SelfNode.Name
            ?? definition.hostname
        let newID = WorkspaceIdentity(loginName: loginName,
                                       displayName: displayName,
                                       tailnetName: tailnetName,
                                       hostname: hostname)
        persistIdentity(newID)
    }

    private func persistIdentity(_ newIdentity: WorkspaceIdentity) {
        guard newIdentity != identity else { return }
        identity = newIdentity
        definition.lastKnownIdentity = newIdentity
        onChange?(definition)
    }

}
