// Copyright (c) Tailscale Inc & contributors
// SPDX-License-Identifier: BSD-3-Clause

//  WorkspaceStore.swift
//  Latchkey
//
//  On-disk persistence for the workspace list + per-workspace path helpers.
//
//  Each workspace is a separate Tailscale (tsnet) identity, so each one gets
//  its own state directory and (via the definition) its own
//  WKWebsiteDataStore UUID. Everything lives under the
//  app's persistent Application Support — NOT NSTemporaryDirectory, which iOS
//  purges under storage pressure (a logged-in node could silently lose its
//  credentials). Process-wide logtail state also uses Application Support;
//  this does the same for tsnet state.
//
//  Layout:
//
//    <Application Support>/Latchkey/
//        workspaces.json                 # [WorkspaceDefinition] + activeId
//        Workspaces/<id>/
//            state/                       # tsnet state dir (tailscale_set_dir)
//
//  No page URL is stored anywhere (revision R2); `tabs.json` from earlier
//  builds is deleted on sight.
//
//  Auth keys are NEVER stored here — they come from launch args/env (tests) or
//  persist implicitly inside each workspace's tsnet state dir (real logins).
//  UI tests use a separate top-level Application Support namespace, so their
//  state can never reset or delete a normal app session (even though the app
//  and UI-test target intentionally share a bundle identifier).
//

import Foundation
import TailscaleKit
#if canImport(UIKit)
import UIKit
#endif

/// The last-known Tailscale identity for a workspace, persisted so the
/// workspace identifier can render immediately on the next launch (before the
/// node has reconnected), then live-updated from the netmap/prefs once
/// connected. See `Workspace.refreshIdentity`.
struct WorkspaceIdentity: Codable, Equatable {
    var loginName: String?
    var displayName: String?
    var tailnetName: String?
    var hostname: String?
}

/// The persisted definition of a workspace. The in-memory `Workspace` object is
/// built from this; changes are written back through `Workspace`'s `onChange`
/// closure (set by `WorkspaceManager`).
struct WorkspaceDefinition: Codable, Identifiable {
    let id: UUID
    var displayName: String
    var hostname: String
    var homePageURL: String
    var controlURL: String
    var ephemeral: Bool
    /// Stable UUID for this workspace's `WKWebsiteDataStore` — keeps the HTTP
    /// cache / cookies / service workers isolated per identity and stable
    /// across launches.
    var dataStoreUUID: UUID
    /// Last-known identity, persisted for immediate display on next launch.
    var lastKnownIdentity: WorkspaceIdentity?

    /// The single workspace created on first launch (or when the list is
    /// empty): a deliberate tailnet hostname, the default gateway, the default
    /// control URL, and the launch-arg ephemeral flag.
    static func makeDefault() -> WorkspaceDefinition {
        WorkspaceDefinition(
            id: UUID(),
            displayName: "Latchkey",
            hostname: defaultHostName,
            homePageURL: HomePage.defaultURL,
            controlURL: kDefaultControlURL,
            ephemeral: TSNetManager.launchEphemeral(),
            dataStoreUUID: UUID(),
            lastKnownIdentity: nil
        )
    }

    /// The tailnet node's name, fixed before it first signs in (revision R6).
    ///
    /// Upstream used a random `aperture-NNNNNN`. The name matters more than it
    /// looks: KiroCrew pins identity-bound sessions to `login|node name`
    /// (`ts:node:<login>|<Name>`), so renaming the node after the first
    /// dashboard sign-in signs the app out. It is also what an admin sees
    /// when moving the node out of the purgatory pool (§C O3b). So it is
    /// recognisable and set from the start. `latchkey-iphone` was proposed in
    /// R6 and put to Olof; the iPad variant keeps the same shape.
    ///
    /// If a node with this name already exists in the tailnet — say, from an
    /// earlier install whose node was never logged out — control assigns the
    /// new one a suffixed MagicDNS name (`latchkey-iphone-1`). R32's "reset
    /// app" logs the node out so reinstalls do not accumulate.
    /// Kept as `latchkey-*` through the 2026-09-23 rename to Latchkey. This
    /// is a **tailnet identity**, not a brand string: it is the node's MagicDNS
    /// name, it is what Olof's admin console and any host-scoped ACL grant
    /// refer to, and a live install carries its own copy in `workspaces.json`
    /// regardless of this default. Changing it would rename only future fresh
    /// installs, producing a node Olof has to re-approve under a name his
    /// grants may not cover — churn for a cosmetic gain. Rename it only
    /// together with the grant that admits it.
    static var defaultHostName: String {
#if canImport(UIKit)
        UIDevice.current.userInterfaceIdiom == .pad ? "latchkey-ipad" : "latchkey-iphone"
#else
        "latchkey"
#endif
    }
}

/// Persists the workspace list + computes per-workspace paths. All members are
/// `@MainActor` (the module is MainActor-isolated by default).
@MainActor
enum WorkspaceStore {
    /// UI tests must not share the persistent credential/state directory with
    /// the normal app. This matters especially on native macOS, where the UI
    /// test launches the same bundle identifier as the user's running app.
    ///
    /// The explicit `-UITest...` / `-Test...` check covers the launch hooks
    /// used by the suites (`-TestControlURL` alone once sent a relaunch to
    /// the REAL directory: M5). The XCTest environment check also protects
    /// newly-added tests that forget to add a reset hook. Neither signal
    /// exists during a normal app launch.
    ///
    /// Deliberately NOT behind TestHooks (R15). It grants no capability — it
    /// only moves a test run's data to a separate directory — and it has to
    /// hold in every build, so a test run can never touch a real session.
    private static let isUITestProcess: Bool = {
        let process = ProcessInfo.processInfo
        if process.arguments.dropFirst().contains(where: { $0.hasPrefix("-UITest") || $0.hasPrefix("-Test") }) {
            return true
        }
        let environment = process.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCInjectBundleInto"] != nil
    }()

    /// Root for all Latchkey data. Normal launches use
    /// `<Application Support>/Latchkey/`; UI tests use a platform-specific
    /// sibling so iOS and macOS test credentials are isolated from normal
    /// credentials and from each other.
    ///
    /// **The directory names below deliberately still spell the OLD product
    /// name, and must not be "corrected" to match the new one.** The product
    /// was renamed on 2026-09-23 but
    /// the bundle id stayed `net.lixom.latchkey`, so this is the *same app
    /// container* as before, and this directory is live: it holds each
    /// workspace's tsnet state dir — the node's identity — plus
    /// `workspaces.json` and the logs. Renaming the literal would point the app
    /// at an empty directory and silently discard the Tailscale node: new node
    /// key, fresh login, tailnet-lock re-signing, new grants. Nothing would
    /// crash; the owner would just find themselves logged out with an
    /// unapproved device. If it is ever worth renaming, it needs a migration
    /// that moves the directory first and is tested against a populated one.
    /// See `scripts/rename-to-latchkey.py` for the full reasoning.
    static var appSupportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
#if os(iOS)
        let name = isUITestProcess ? "Latchkey-UI-Test-iOS" : "Latchkey"
#elseif os(macOS)
        let name = isUITestProcess ? "Latchkey-UI-Test-macOS" : "Latchkey"
#else
        let name = isUITestProcess ? "Latchkey-UI-Test" : "Latchkey"
#endif
        let dir = base.appending(path: name, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir,
                                                 withIntermediateDirectories: true)
        return dir
    }()

    /// Process-wide filch/logtail state, independent of workspace/login resets.
    static var logsDir: URL = {
        let dir = appSupportDir.appending(path: "Logs", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// `appSupportDir/Workspaces/` (created lazily).
    static var workspacesDir: URL = {
        let dir = appSupportDir.appending(path: "Workspaces", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// `appSupportDir/workspaces.json` — the workspace list + active id.
    static var definitionsFile: URL {
        appSupportDir.appending(path: "workspaces.json")
    }

    /// `<workspacesDir>/<id>/` — a workspace's private directory (created).
    static func workspaceDir(_ id: UUID) -> URL {
        let dir = workspacesDir.appending(path: id.uuidString, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// `<workspaceDir>/state/` — the tsnet state dir passed to
    /// `tailscale_set_dir`. Created so `tailscale_set_dir` has a writable home.
    static func stateDir(_ id: UUID) -> URL {
        let dir = workspaceDir(id).appending(path: "state", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }


    static func tabsURL(_ id: UUID) -> URL {
        workspaceDir(id).appending(path: "tabs.json")
    }

    /// Deletes a `tabs.json` left by a build before revision R2, which
    /// persisted the page URL — and so, after a sign-in, the token.
    static func removeTabs(_ workspaceID: UUID) {
        try? FileManager.default.removeItem(at: tabsURL(workspaceID))
    }

    // MARK: - Load / save

    /// On-disk envelope for `workspaces.json`.
    private struct Envelope: Codable {
        var workspaces: [WorkspaceDefinition]
        var activeId: UUID?
    }

    /// Loads the workspace list + active id, or nil if there's no file yet
    /// (first launch) or it can't be decoded (treated as a fresh start).
    static func load() -> (workspaces: [WorkspaceDefinition], activeId: UUID?)? {
        guard let data = try? Data(contentsOf: definitionsFile),
              let env = try? JSONDecoder().decode(Envelope.self, from: data)
        else { return nil }
        return (env.workspaces, env.activeId)
    }

    /// Atomically writes the workspace list + active id.
    static func save(_ workspaces: [WorkspaceDefinition], activeId: UUID?) {
        let env = Envelope(workspaces: workspaces, activeId: activeId)
        guard let data = try? JSONEncoder().encode(env) else { return }
        try? data.write(to: definitionsFile, options: .atomic)
    }

    /// Removes a workspace's entire on-disk directory (state + bookmarks).
    static func removeWorkspaceDir(_ id: UUID) {
        try? FileManager.default.removeItem(at: workspaceDir(id))
    }
}


