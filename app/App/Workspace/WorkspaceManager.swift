// Copyright (c) Tailscale Inc & contributors
// SPDX-License-Identifier: BSD-3-Clause

//  WorkspaceManager.swift
//  Latchkey
//
//  The app-level coordinator: owns the workspace list + the active workspace,
//  initializes process-wide persistent logging, applies the UI-test
//  launch-arg resets across all workspaces, fans out `scenePhase` to every
//  workspace, and persists the workspace list. Replaces the old single
//  `TSNetManager` held directly by `LatchkeyApp`.
//
//  In Phase 1 there is exactly one workspace (the default), so behavior is
//  identical to the pre-refactor app. The concurrency plumbing for multiple
//  live workspaces lands in Phase 2; creating a second workspace lands in
//  Phase 3.
//

import Combine
import SwiftUI
import TailscaleKit
import WebKit

@MainActor
final class WorkspaceManager: ObservableObject {
    @Published private(set) var workspaces: [Workspace] = []
    @Published private(set) var activeWorkspace: Workspace?

    private var activeId: UUID?
    /// workspaceID -> windowID for currently open workspace windows. At most
    /// one window per workspace is allowed (a second window in the same
    /// workspace would share one `TabManager` and fight it, so Cmd+N refuses
    /// to open one). In-memory only.
    @Published private(set) var openWorkspaceWindows: [UUID: UUID] = [:]
    /// The most recently focused (key) workspace window's workspace. Retained
    /// when its window closes so Cmd+N can reopen it after ALL windows are
    /// gone (the last workspace to have focus is the one to reopen). Mirrored
    /// into the persisted `activeWorkspace` on each focus. In-memory only; on
    /// relaunch it falls back to the persisted active workspace.
    private(set) var lastFocusedWorkspaceID: UUID?
    /// Shared launch-only auth key used by automation. Never persisted.
    private let authKey: String?

    init() {
        // App-level one-time setup — MUST run before any TailscaleNode is
        // created so all nodes share one logtail and Go runtime stderr is
        // captured by its persistent filch from the beginning.
        //
        // UI-test hook: start from empty node logs, so every line in them
        // is this launch's (the node-log test must not pass on an earlier
        // run's lines).
        if TestHooks.flag("-UITestResetNodeLog") {
            NodeLog.removeFiles(in: WorkspaceStore.logsDir)
        }
        //
        // A failure is not a trap (F8 §4.6): the app runs, and no node is
        // created until logging works — `TSNetManager` asks `ProcessLogging`
        // before every start and shows the refusal on the gate (G7).
        if let error = ProcessLogging.setUp() {
            logger.log("NODE START REFUSED at launch: process logging is unavailable: \(error). No node will be started until it is; nothing on disk has been changed.")
        }

        // Before any node key or cookie is written (R5): the data root holds
        // the node keys, WebKit's store the 30-day refresh cookie.
        logger.log(BackupExclusion.apply(appSupportRoot: WorkspaceStore.appSupportDir))

        // Load the workspace list, or seed a single default on first launch.
        //
        // Three answers, not two. "No file" and "a file that cannot be read"
        // used to be the same nil, and both took the seed-and-save branch: a
        // damaged workspaces.json was overwritten with a new default, and the
        // old node's state directory — its identity — was orphaned without a
        // log line. Now an unreadable file is left exactly as it is (save()
        // refuses to write over it too), the app runs on a fixed recovery
        // workspace so Settings → Logs stays reachable, and the log says what
        // happened and where the file is. Nothing on disk is deleted.
        var defs: [WorkspaceDefinition]
        switch WorkspaceStore.load() {
        case .loaded(let loaded, let loadedActiveId, let repairs, let rejected) where !loaded.isEmpty:
            defs = loaded
            activeId = loadedActiveId
            for line in repairs { logger.log("workspaces.json: \(line)") }
            for line in rejected { logger.log("workspaces.json: entry REJECTED, kept in a copy beside the file: \(line)") }
        case .absent, .loaded:
            // First launch, or a decodable file whose list is empty: nothing
            // to keep, and the file (if any) is one save() may overwrite.
            let d = WorkspaceDefinition.makeDefault()
            defs = [d]
            activeId = d.id
            WorkspaceStore.save(defs, activeId: activeId)
        case .unreadable(let reason):
            let d = WorkspaceDefinition.makeRecovery()
            defs = [d]
            activeId = d.id
            logger.log("""
                WORKSPACE FILE PRESERVED, NOT LOADED: workspaces.json \(reason). \
                It has not been overwritten and no workspace directory has been deleted: every node's \
                identity is still under Workspaces/. Running on the recovery workspace \(d.hostname) \
                (\(d.id)); nothing is saved until the file is repaired or removed. To recover, fix or \
                remove <Application Support>/Latchkey/workspaces.json from the app container \
                (Xcode > Devices > download container).
                """)
            // Deliberately not saved. WorkspaceStore.save would refuse anyway.
        }

        // Hermetic multi-workspace UI-test hook. Remove all prior workspace
        // data and seed one fresh definition before any tsnet node is created.
        if TestHooks.flag("-UITestResetWorkspaces") {
            for d in defs { WorkspaceStore.removeWorkspaceDir(d.id) }
            let d = WorkspaceDefinition.makeDefault()
            defs = [d]
            activeId = d.id
            // The web data too. Removing only the workspace dirs left every
            // earlier test's WKWebsiteDataStore on disk — 111 of them after
            // a few suite runs — and scripts/test-offline.sh's R1 disk scan
            // then read other suites' caches (M4). The new store is not
            // created yet and is never in the list removed here.
            // `-UITestKeepWebData` opts out, for suites whose leak scan must
            // see every test's data, not only the last one's (M4 review).
            if !TestHooks.flag("-UITestKeepWebData") {
                Self.removeWebsiteDataStores(except: d.dataStoreUUID)
            }
        }

        // UI-test hook: wipe every workspace's tsnet state dir so the next
        // launch starts from NeedsLogin (the connection gate) rather than
        // silently re-using a login a prior test left behind. Harmless in
        // normal use — the launch argument is never set outside UI tests.
        // Must run before the workspaces (and their nodes) are created.
        if TestHooks.flag("-UITestResetLogin") {
            for d in defs { try? FileManager.default.removeItem(at: WorkspaceStore.stateDir(d.id)) }
        }

        // UI-test hook: reset every workspace's home page to the default so
        // connected tests are hermetic (a prior test may have left a non-default
        // value). Mirrors the old `HomePage.standard.url = default` in
        // `LatchkeyApp.init`.
        if TestHooks.flag("-UITestResetHomePage") {
            defs = defs.map {
                var d = $0
                d.homePageURL = HomePage.defaultURL
                return d
            }
        }

        // UI-test-only override for flows that exercise authentication rather
        // than a particular tailnet web service. Keeping those tests on a
        // direct HTTPS page prevents an unrelated private-service outage from
        // masquerading as a login failure.
        if let raw = TestHooks.value("-UITestHomePage") {
            let testURL = GatewayAddress.persistable(raw)
            defs = defs.map {
                var d = $0
                d.homePageURL = testURL
                return d
            }
        }

        // UI-test hook (F5): the switcher's remembered gateways, most recent
        // first, comma-separated. How a test puts a gateway on the list that
        // the tailnet does not carry, or one that is dead.
        if let raw = TestHooks.value("-UITestKnownGateways") {
            let list = raw.split(separator: ",").compactMap { WorkspaceDefinition.knownOrigin(String($0)) }
            defs = defs.map {
                var d = $0
                d.knownGateways = list
                return d
            }
        }

        if activeId == nil { activeId = defs.first?.id }

        // The shared launch-arg auth key (tests). Applied to every workspace —
        // in tests all workspaces join the same tailnet with the same user,
        // differing only by hostname. Real (non-test) workspaces have a nil
        // key and authenticate via web auth. NOT persisted.
        let authKey = TSNetManager.launchAuthKey()
        self.authKey = authKey

        // Ephemeral is a launch-time input for test nodes (the APERTURE_EPHEMERAL
        // env / -Ephemeral arg), re-resolved every launch — matching the
        // pre-refactor behavior where `TSNetManager.init` read it fresh each
        // launch. When the launch flag is explicitly set, override the persisted
        // definition so test nodes register ephemeral (auto-cleanup) even if the
        // definition was first created by a connection-independent test launch
        // that didn't set the flag. When the flag is absent, leave the
        // definition's value alone (a real user's persistent workspace stays
        // non-ephemeral; a user-created ephemeral workspace stays ephemeral).
        if TSNetManager.launchEphemeral() {
            defs = defs.map {
                var d = $0
                d.ephemeral = true
                return d
            }
        }

        self.workspaces = defs.map { def in
            Workspace(definition: def, authKey: authKey) { [weak self] updated in
                self?.handleDefinitionChange(updated)
            }
        }
        self.activeWorkspace = workspaces.first(where: { $0.id == activeId }) ?? workspaces.first
        self.activeId = self.activeWorkspace?.id

        // Persist once up front so the test-reset home-page edits (above) and
        // any default seeding are written even if nothing else changes.
        persist()
    }

    // MARK: - Workspace actions

    func workspace(id: UUID) -> Workspace? {
        workspaces.first(where: { $0.id == id })
    }

    /// Creates and immediately activates a fresh, independently persisted
    /// tsnet identity. Constructing `Workspace` starts its node; existing
    /// workspaces remain alive and are not torn down when selection changes.
    @discardableResult
    func addWorkspace() -> Workspace {
        let workspace = makeWorkspace(from: .makeDefault())
        workspaces.append(workspace)
        activeWorkspace = workspace
        activeId = workspace.id
        persist()
        return workspace
    }

    /// Changes only which workspace is rendered. Every workspace's tsnet node
    /// continues running in the background.
    func selectWorkspace(id: UUID) {
        guard let workspace = workspaces.first(where: { $0.id == id }),
              workspace.id != activeId else { return }
        activeWorkspace = workspace
        activeId = workspace.id
        persist()
    }

    /// A workspace window appeared. Records it as open and, if no window has
    /// been focused yet, treats it as the current workspace. Idempotent: a
    /// no-op when the window is already recorded as open, so re-registration
    /// (e.g. from a SwiftUI view re-render) does not publish.
    func windowDidOpen(windowID: UUID, workspaceID: UUID) {
        if openWorkspaceWindows[workspaceID] == windowID, lastFocusedWorkspaceID != nil {
            return
        }
        openWorkspaceWindows[workspaceID] = windowID
        if lastFocusedWorkspaceID == nil { lastFocusedWorkspaceID = workspaceID }
        selectWorkspace(id: workspaceID)
    }

    /// A workspace window became key. Updates the most-recently-focused
    /// workspace (the Cmd+N target) and mirrors it into the persisted active
    /// workspace. Driven by NSWindow.didBecomeKeyNotification for reliability
    /// (per-scene scenePhase does not reliably fire on macOS when another
    /// window closes and this one becomes key). Idempotent.
    func windowBecameKey(windowID: UUID, workspaceID: UUID) {
        guard lastFocusedWorkspaceID != workspaceID else { return }
        lastFocusedWorkspaceID = workspaceID
        selectWorkspace(id: workspaceID)
    }

    /// A workspace window closed. Removes it from the open set only when the
    /// closing window is the one currently recorded as open for this workspace.
    /// Keying the removal on `windowID` (not just `workspaceID`) is what makes
    /// the close→reopen sequence correct: the dismissed window's `onDisappear`
    /// fires asynchronously (SwiftUI tears the window down whenever it gets
    /// around to it), and a Cmd+N issued right after Cmd+W opens the
    /// replacement window *before* the old view's `onDisappear` runs. If that
    /// late cleanup were keyed only by `workspaceID` it would wipe the new
    /// window's entry, `hasOpenWindow` would report false, and the next Cmd+N
    /// would open a second window on the same workspace. Matching the windowID
    /// makes the stale cleanup a no-op. `lastFocusedWorkspaceID` is
    /// intentionally retained so Cmd+N can reopen the last-focused workspace
    /// after all windows are closed.
    func windowDidClose(windowID: UUID, workspaceID: UUID) {
        guard openWorkspaceWindows[workspaceID] == windowID else { return }
        openWorkspaceWindows.removeValue(forKey: workspaceID)
    }

    /// True if this workspace currently has an open window.
    func hasOpenWindow(_ workspaceID: UUID) -> Bool {
        openWorkspaceWindows[workspaceID] != nil
    }

    /// The workspace Cmd+N / "new window" should target: the most recently
    /// focused one that still exists, falling back to the persisted active
    /// workspace. Returns nil only if there are no workspaces at all.
    var currentWorkspaceID: UUID? {
        let candidate = lastFocusedWorkspaceID ?? activeId ?? activeWorkspace?.id
        if let candidate, workspaces.contains(where: { $0.id == candidate }) {
            return candidate
        }
        return activeWorkspace?.id ?? workspaces.first?.id
    }

    /// Removes a session rather than leaving a logged-out shell behind. If it
    /// was the final session, create and activate a fresh blank one first so
    /// the app always has a valid workspace and immediately returns to the
    /// connection gate.
    func deleteWorkspace(id: UUID) {
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else { return }
        let removed = workspaces[index]

        var replacement: Workspace?
        if workspaces.count == 1 {
            replacement = makeWorkspace(from: .makeDefault())
        } else if activeId == id {
            replacement = workspaces[index == workspaces.count - 1 ? index - 1 : index + 1]
        }

        workspaces.remove(at: index)
        if let replacement {
            if workspaces.isEmpty { workspaces.append(replacement) }
            activeWorkspace = replacement
            activeId = replacement.id
            // If the deleted workspace was the most-recently-focused one, hand
            // that role to the replacement so Cmd+N still has a valid target.
            if lastFocusedWorkspaceID == id { lastFocusedWorkspaceID = replacement.id }
        }
        openWorkspaceWindows.removeValue(forKey: id)
        persist()

        // Publish the replacement/removal immediately, then tear down and
        // erase the old session away from the button action. The Workspace is
        // retained by this task until its node and stores are no longer in use.
        Task {
            await removed.deleteSessionData()
        }
    }

    private func makeWorkspace(from definition: WorkspaceDefinition) -> Workspace {
        Workspace(definition: definition, authKey: authKey) { [weak self] updated in
            self?.handleDefinitionChange(updated)
        }
    }

    // MARK: - Lifecycle

    func willEnterBackground() {
        for w in workspaces { w.willEnterBackground() }
    }

    func willEnterForeground() {
        for w in workspaces { w.willEnterForeground() }
    }

    // MARK: - Persistence

    /// A workspace reports a definition change here; update the in-memory list
    /// and re-save the whole list to disk.
    private func handleDefinitionChange(_ updated: WorkspaceDefinition) {
        // The owning Workspace already mutated its own `definition` (it's the
        // source of truth); we just need to persist the full list.
        persist()
    }

    private func persist() {
        WorkspaceStore.save(workspaces.map { $0.definition }, activeId: activeId)
    }

}

extension WorkspaceManager {
    /// Test hook support: deletes every web data store except `keep`.
    /// Asynchronous, because WebKit's removal is; stores still in use (none
    /// should be, at launch) are skipped and logged.
    static func removeWebsiteDataStores(except keep: UUID) {
        Task { @MainActor in
            let ids = await WKWebsiteDataStore.allDataStoreIdentifiers
            for id in ids where id != keep {
                do {
                    try await WKWebsiteDataStore.remove(forIdentifier: id)
                } catch {
                    logger.log("UITest reset: could not remove a web data store: \(LogRedaction.describe(error))")
                }
            }
        }
    }
}
