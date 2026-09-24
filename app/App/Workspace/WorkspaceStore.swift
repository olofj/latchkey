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
//  workspaces.json is never written over a file that exists and does not
//  decode (`load` / `save` below): those state dirs are each node's identity.
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

    static let defaultDisplayName = "Latchkey"

    /// The single workspace created on first launch (or when the list is
    /// empty): a deliberate tailnet hostname, the default gateway, the default
    /// control URL, and the launch-arg ephemeral flag.
    static func makeDefault() -> WorkspaceDefinition {
        WorkspaceDefinition(
            id: UUID(),
            displayName: defaultDisplayName,
            hostname: defaultHostName,
            homePageURL: HomePage.defaultURL,
            controlURL: kDefaultControlURL,
            ephemeral: TSNetManager.launchEphemeral(),
            dataStoreUUID: UUID(),
            lastKnownIdentity: nil
        )
    }

    /// The workspace the app runs on when `workspaces.json` exists but cannot
    /// be read (`WorkspaceStore.LoadOutcome.unreadable`): the file and every
    /// state directory are being preserved, and the app still needs one
    /// workspace so Settings — and its Logs, the only place the owner can read
    /// what happened on a device — stays reachable.
    ///
    /// The ids are **fixed**, so every launch in that state uses the same node
    /// state dir and web data store: a sign-in made while degraded survives a
    /// relaunch instead of being orphaned, and the container does not grow a
    /// new directory per launch. The hostname is distinct, so a degraded node
    /// is recognisable in the tailnet admin console and cannot take the real
    /// node's name (which would hand the real node a `-1` suffix once the file
    /// is repaired). `ephemeral` follows the launch flag as `makeDefault` does.
    static let recoveryID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    static let recoveryDataStoreUUID = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!

    static func makeRecovery() -> WorkspaceDefinition {
        WorkspaceDefinition(
            id: recoveryID,
            displayName: "\(defaultDisplayName) (recovery)",
            hostname: "\(defaultHostName)-recovery",
            homePageURL: HomePage.defaultURL,
            controlURL: kDefaultControlURL,
            ephemeral: TSNetManager.launchEphemeral(),
            dataStoreUUID: recoveryDataStoreUUID,
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
    /// recognisable and set from the start. R6 proposed the name and put it to
    /// Olof; the iPad variant keeps the same shape.
    ///
    /// If a node with this name already exists in the tailnet — say, from an
    /// earlier install whose node was never logged out — control assigns the
    /// new one a suffixed MagicDNS name (`latchkey-iphone-1`). R32's "reset
    /// app" logs the node out so reinstalls do not accumulate.
    ///
    /// **This default follows the product name; the data root does not.** The
    /// rename of 2026-09-23 moved it to `latchkey-*`, and that is safe where
    /// renaming the Application Support directory would not have been: this
    /// value is only a *default*, and a live install has its own copy in
    /// `workspaces.json`, so an existing node keeps the name it registered
    /// with and nothing is logged out. Only a fresh install picks up the new
    /// name — and a fresh install has to be re-approved anyway, because its
    /// node key is new. Checked against the tailnet policy too (D5): the grant
    /// is scoped by *address range* (`kiro-clients`), not by node name, so a
    /// renamed node needs no grant change.
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

    /// On-disk envelope for `workspaces.json`, as written.
    private struct Envelope: Encodable {
        var workspaces: [WorkspaceDefinition]
        var activeId: UUID?
    }

    /// The same envelope, as read.
    private struct DecodedEnvelope: Decodable {
        var workspaces: [WorkspaceDefinition]
        var activeId: UUID?
    }

    /// What was found at `definitionsFile`.
    enum LoadOutcome {
        /// No file: the first launch. Seeding a default and writing it is right.
        case absent
        /// A list. `repairs` are fields that took a default; `rejected` are
        /// entries that could not be used. (Both empty until the decoder is
        /// made tolerant; the shape is the contract the manager logs from.)
        case loaded(workspaces: [WorkspaceDefinition], activeId: UUID?, repairs: [String], rejected: [String])
        /// The file exists and could not be read or decoded — an I/O error, an
        /// empty or truncated file. It, and every state directory it might
        /// name, must be left exactly as they are.
        case unreadable(reason: String)

        /// What the manager does with it. Pure, so the host test can pin the
        /// decision per document (`scripts/test-workspace-store.sh`).
        var decision: Decision {
            switch self {
            case .absent:
                return .freshStart
            case .loaded(let workspaces, _, _, let rejected):
                // A decodable file with an empty list holds nothing to keep,
                // and save() may overwrite it: the same fresh start as no file.
                return workspaces.isEmpty ? .freshStart : .keep(workspaces: workspaces.count, rejected: rejected.count)
            case .unreadable:
                return .preserve
            }
        }
    }

    enum Decision: Equatable {
        /// Seed the default workspace and write the file.
        case freshStart
        /// Run the workspaces that decoded.
        case keep(workspaces: Int, rejected: Int)
        /// Touch nothing on disk; run a recovery workspace; say so loudly.
        case preserve
    }

    /// Loads the workspace list + active id.
    ///
    /// "No file" and "a file that cannot be read" are different answers.
    /// The old `try?` chain returned nil for both, and the caller treated nil
    /// as a first launch: a damaged `workspaces.json` was overwritten with a
    /// new default and the old node's state directory was orphaned without a
    /// log line. Only a missing file is `.absent`.
    static func load() -> LoadOutcome {
        load(from: definitionsFile)
    }

    static func load(from file: URL) -> LoadOutcome {
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch {
            let ns = error as NSError
            let noSuchFile = (ns.domain == NSCocoaErrorDomain && ns.code == NSFileReadNoSuchFileError)
                || (ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOENT))
            if noSuchFile { return .absent }
            return .unreadable(reason: "cannot be read: \(describe(error))")
        }
        if data.isEmpty { return .unreadable(reason: "is empty (0 bytes)") }

        let env: DecodedEnvelope
        do {
            env = try JSONDecoder().decode(DecodedEnvelope.self, from: data)
        } catch {
            return .unreadable(reason: "does not decode: \(describe(error))")
        }
        return .loaded(workspaces: env.workspaces, activeId: env.activeId, repairs: [], rejected: [])
    }

    /// Atomically writes the workspace list + active id — **unless the file
    /// on disk exists and cannot be read**, in which case nothing is written
    /// and the refusal is logged. That is the guarantee: a `workspaces.json`
    /// the app cannot decode is never replaced, whatever the caller thinks
    /// the list is. Returns whether the file was written.
    @discardableResult
    static func save(_ workspaces: [WorkspaceDefinition], activeId: UUID?) -> Bool {
        save(workspaces, activeId: activeId, to: definitionsFile)
    }

    @discardableResult
    static func save(_ workspaces: [WorkspaceDefinition], activeId: UUID?, to file: URL) -> Bool {
        switch load(from: file) {
        case .absent, .loaded:
            break
        case .unreadable(let reason):
            refuseWrite(because: "the file on disk \(reason)")
            return false
        }
        let env = Envelope(workspaces: workspaces, activeId: activeId)
        do {
            let data = try JSONEncoder().encode(env)
            try data.write(to: file, options: .atomic)
            return true
        } catch {
            logger.log("workspaces.json could not be written: \(describe(error))")
            return false
        }
    }

    /// Logged once per reason per launch: identity refreshes persist too, and
    /// the line should stay legible in Settings → Logs.
    private static var lastRefusal: String?
    private static func refuseWrite(because reason: String) {
        guard lastRefusal != reason else { return }
        lastRefusal = reason
        logger.log("workspaces.json NOT written: \(reason). It is preserved as it is, and no workspace directory has been touched.")
    }

    /// A decode or I/O error, without an `NSError`'s userInfo dump. The values
    /// in the file are hostnames and an origin, and the codingPath is enough
    /// to point at the field; `Logger.log` scrubs the line again anyway.
    nonisolated private static func describe(_ error: (any Error)?) -> String {
        guard let error else { return "unknown error" }
        if let decoding = error as? DecodingError {
            let context: DecodingError.Context
            switch decoding {
            case .typeMismatch(_, let ctx), .valueNotFound(_, let ctx),
                 .keyNotFound(_, let ctx), .dataCorrupted(let ctx):
                context = ctx
            @unknown default:
                return "\(type(of: decoding))"
            }
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            let text = context.debugDescription.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            return path.isEmpty ? text : "\(path): \(text)"
        }
        let ns = error as NSError
        let text = ns.localizedDescription.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return "\(ns.domain) \(ns.code): \(text)"
    }

    /// Removes a workspace's entire on-disk directory (state + bookmarks).
    static func removeWorkspaceDir(_ id: UUID) {
        try? FileManager.default.removeItem(at: workspaceDir(id))
    }
}


