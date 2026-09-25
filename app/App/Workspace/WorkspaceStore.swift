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
//        workspaces.json.rejected-<time> # the original, kept when save() had
//                                        # to drop an entry it could not decode
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
    /// Set the first time this workspace's node reaches `Running` (F11 §4.2),
    /// and never cleared. The connection gate introduces the app only while
    /// it is false, so a returning user whose key expired is not introduced
    /// to an app they have been using for months.
    var hasEverConnected: Bool
    /// F6 §4.1a: whether the page may load the four widget CDNs. Optional,
    /// and absent in every file written before F6: absent reads as `true`,
    /// Olof's default. Read it through `widgetCDNsAllowed`.
    var allowWidgetCDNs: Bool?

    /// *Allow widget CDNs*, with an absent value read as on.
    var widgetCDNsAllowed: Bool { allowWidgetCDNs ?? true }

    /// The on-disk keys, unchanged. Named so the tolerant `init(from:)` below
    /// and the synthesized `encode(to:)` agree. **A new field goes here, in
    /// `init(from:)` with a default or as an optional, and nowhere else** —
    /// see the decoding rules on `init(from:)`.
    enum CodingKeys: String, CodingKey {
        case id, displayName, hostname, homePageURL, controlURL, ephemeral,
             dataStoreUUID, lastKnownIdentity, hasEverConnected, allowWidgetCDNs
    }

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
            lastKnownIdentity: nil,
            hasEverConnected: false
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
            lastKnownIdentity: nil,
            // A workspaces.json exists, so this install has run before.
            hasEverConnected: true
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

/// What the tolerant decoder filled in or threw away, collected through
/// `Decoder.userInfo` so `WorkspaceStore.load` can report it. A class, so the
/// value-typed `init(from:)` can append to it; `userInfo` values must be
/// `Sendable`, hence the lock (the decode itself is synchronous, so it is
/// never contended — it is there to make the promise checkable).
nonisolated final class WorkspaceDecodeNotes: @unchecked Sendable {
    private let lock = NSLock()
    private var repairLines: [String] = []
    private var rejectedLines: [String] = []

    /// A field that was absent, null or the wrong type and took its default.
    var repairs: [String] { lock.withLock { repairLines } }
    /// A list entry that could not be used at all (no usable `id`).
    var rejected: [String] { lock.withLock { rejectedLines } }

    func repaired(_ line: String) { lock.withLock { repairLines.append(line) } }
    func rejected(_ line: String) { lock.withLock { rejectedLines.append(line) } }
}

extension CodingUserInfoKey {
    static let workspaceDecodeNotes = CodingUserInfoKey(rawValue: "net.lixom.latchkey.workspaceDecodeNotes")!
    /// The `Workspaces/` directory beside the file being decoded (a `URL`),
    /// where a missing `hasEverConnected` looks for its evidence.
    static let workspacesRoot = CodingUserInfoKey(rawValue: "net.lixom.latchkey.workspacesRoot")!
}

extension WorkspaceDefinition {
    /// Tolerant decoding: an entry is rejected only when it cannot be tied to
    /// its state directory; every other field takes a default.
    ///
    /// Why this is hand-written. The synthesized decoder failed the **whole
    /// list** when any one non-optional key was absent, null or the wrong
    /// type, and `WorkspaceStore.load` reported that as "no file": the
    /// manager then minted a new default and saved over the file, orphaning
    /// `Workspaces/<old-id>/state` — the tsnet node's identity — with no log
    /// line. Nothing in the file today can trigger it; the next field anyone
    /// adds can, on the first launch after the upgrade. This makes that
    /// impossible by construction rather than by remembering to write `?`.
    ///
    /// Which fields are load-bearing, and why:
    ///
    /// - `id` — **required.** It names `Workspaces/<id>/state`. Without it
    ///   there is no way to know which directory this entry owns, and guessing
    ///   (say, a new UUID) would silently orphan the real one, which is the
    ///   exact defect. Foundation's `UUID(uuidString:)` also insists on
    ///   hyphens; a 32-digit hex string names exactly one UUID, so that form
    ///   is accepted too. An entry without a usable `id` is rejected on its
    ///   own; `WorkspaceStore` keeps the others and reports the rejection.
    /// - `dataStoreUUID` — defaults to a **fresh** UUID, with a note. It names
    ///   the `WKWebsiteDataStore` (cookies, the dashboard's 30-day refresh
    ///   cookie). Losing it costs one dashboard sign-in, which is recoverable;
    ///   the node's identity is not, so the two are not treated alike.
    /// - `ephemeral` — defaults to **false**, never to the launch flag. An
    ///   ephemeral node is deleted by control when it goes offline: the wrong
    ///   default here would *be* identity loss. `WorkspaceManager` still
    ///   applies the test-only launch flag afterwards, as before.
    /// - `hostname` — defaults to `defaultHostName`. The node key lives in the
    ///   state dir, so the node stays the same node; a changed name costs at
    ///   most the KiroCrew session, which is pinned to `login|node name`.
    /// - `controlURL` — defaults to `kDefaultControlURL`, as `makeDefault`.
    /// - `homePageURL` — defaults to `HomePage.defaultURL` ("no gateway
    ///   chosen"): the picker appears, nothing is lost.
    /// - `displayName` — cosmetic; defaults to `defaultDisplayName`.
    /// - `lastKnownIdentity` — a display cache; absent, null or malformed
    ///   reads as nil and is refreshed once the node connects.
    /// - `allowWidgetCDNs` — optional; absent reads as on (F6 §5).
    /// - `hasEverConnected` — absent in every file written before F11, so
    ///   its default is the **evidence**, not `false`: true when this entry's
    ///   `Workspaces/<id>/state` already exists (the install has run before),
    ///   false otherwise. `false` would re-introduce the app to an existing
    ///   user on their next key expiry (F11 §5).
    ///
    /// Every default is recorded in `WorkspaceDecodeNotes` (when the decoder
    /// carries one) so the launch log says what was filled in. Unknown keys
    /// are ignored, as before, so an older build can read a newer file.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let notes = decoder.userInfo[.workspaceDecodeNotes] as? WorkspaceDecodeNotes

        guard let id = Self.uuid(in: c, forKey: .id) else {
            throw DecodingError.dataCorruptedError(
                forKey: .id, in: c, debugDescription: "id is missing or not a UUID")
        }
        self.id = id

        self.displayName = Self.field(.displayName, in: c, default: Self.defaultDisplayName, id: id, notes: notes)
        self.hostname = Self.field(.hostname, in: c, default: Self.defaultHostName, id: id, notes: notes)
        self.homePageURL = Self.field(.homePageURL, in: c, default: HomePage.defaultURL, id: id, notes: notes)
        self.controlURL = Self.field(.controlURL, in: c, default: kDefaultControlURL, id: id, notes: notes)
        self.ephemeral = Self.field(.ephemeral, in: c, default: false, id: id, notes: notes)

        if let stored = Self.uuid(in: c, forKey: .dataStoreUUID) {
            self.dataStoreUUID = stored
        } else {
            self.dataStoreUUID = UUID()
            notes?.repaired("\(id): dataStoreUUID missing or not a UUID; a new web data store was assigned (the dashboard will ask for a sign-in; the node is unaffected)")
        }

        do {
            self.lastKnownIdentity = try c.decodeIfPresent(WorkspaceIdentity.self, forKey: .lastKnownIdentity)
        } catch {
            self.lastKnownIdentity = nil
            notes?.repaired("\(id): lastKnownIdentity unreadable; it will be refreshed from the node")
        }

        // Checked without creating anything: `WorkspaceStore.stateDir`
        // creates the directory it names, which would make this always true.
        let root = decoder.userInfo[.workspacesRoot] as? URL
        let hasNodeDir = root.map { root in
            FileManager.default.fileExists(
                atPath: root.appending(path: id.uuidString).appending(path: "state").path)
        } ?? false
        self.hasEverConnected = Self.field(.hasEverConnected, in: c, default: hasNodeDir, id: id, notes: notes)

        // F6: absent is the normal case for a file from before F6 and is not
        // a repair; only a value of the wrong type is noted.
        do {
            self.allowWidgetCDNs = try c.decodeIfPresent(Bool.self, forKey: .allowWidgetCDNs)
        } catch {
            self.allowWidgetCDNs = nil
            notes?.repaired("\(id): allowWidgetCDNs is not a Bool; widget CDNs stay allowed")
        }
    }

    /// A field with a default: absent and null both read as the default;
    /// so does the wrong type, since the alternative is losing the node over
    /// a cosmetic value. Each is noted.
    private static func field<T: Decodable>(_ key: CodingKeys, in c: KeyedDecodingContainer<CodingKeys>,
                                            default value: T, id: UUID, notes: WorkspaceDecodeNotes?) -> T {
        do {
            if let stored = try c.decodeIfPresent(T.self, forKey: key) { return stored }
            notes?.repaired("\(id): \(key.stringValue) missing; using the default")
        } catch {
            notes?.repaired("\(id): \(key.stringValue) is not a \(T.self); using the default")
        }
        return value
    }

    /// A UUID field, in the hyphenated form Foundation decodes or as 32 hex
    /// digits. nil when absent, null or anything else.
    private static func uuid(in c: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) -> UUID? {
        if let stored = try? c.decodeIfPresent(UUID.self, forKey: key) { return stored }
        guard let text = try? c.decodeIfPresent(String.self, forKey: key) else { return nil }
        return uuid(fromUnhyphenated: text)
    }

    /// `0123456789ABCDEF0123456789ABCDEF` → the UUID it spells, or nil.
    static func uuid(fromUnhyphenated text: String) -> UUID? {
        let hex = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hex.count == 32, hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        var hyphenated = ""
        for (offset, digit) in hex.enumerated() {
            if offset == 8 || offset == 12 || offset == 16 || offset == 20 { hyphenated.append("-") }
            hyphenated.append(digit)
        }
        return UUID(uuidString: hyphenated)
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
    /// **Renaming this literal discards the Tailscale node. It was renamed once,
    /// on purpose, and that is the last time it should happen casually.**
    ///
    /// This directory is live: it holds each workspace's tsnet state dir — the
    /// node's identity — plus `workspaces.json` and the logs. Point the app at a
    /// different name and it finds an empty directory and starts over: new node
    /// key, fresh login, tailnet-lock re-signing, new grants. **Nothing
    /// crashes.** The owner simply finds themselves logged out with an
    /// unapproved device, which is the worst shape a fault can have.
    ///
    /// It moved from the previous product's name to `Latchkey/` on 2026-09-24,
    /// with the bundle id, because the old name was trademark-encumbered and had
    /// to leave the repository — and Olof accepted losing the node for it. No
    /// migration was written: there was exactly one install, and logging it back
    /// in was cheaper than code that would run once. If it is ever renamed
    /// again, it needs a migration that moves the directory first and is tested
    /// against a populated one. See `scripts/rename-to-latchkey.py`.
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

    /// Renames the workspace's `state/` aside so a fresh node can be created,
    /// and returns where it went (F8 §4.4). NEVER deletes: this directory IS
    /// the node's identity, and an owner who taps this is already having a
    /// bad day. The aside copy stays inside the backup-excluded root, which
    /// is right: it holds node keys. Nothing sweeps these up.
    static func setStateDirAside(_ id: UUID, now: Date = Date()) throws -> URL {
        try setAside(stateDir: workspaceDir(id).appending(path: "state", directoryHint: .isDirectory),
                     now: now)
    }

    /// `state/` → `state-aside-<ISO 8601>/` beside it, then an empty `state/`.
    /// A rename in the same directory, so it needs no permission on `state/`
    /// itself: it works for the unreadable directory that is its main case.
    static func setAside(stateDir: URL, now: Date) throws -> URL {
        let fm = FileManager.default
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withYear, .withMonth, .withDay, .withTime, .withTimeZone]
        let parent = stateDir.deletingLastPathComponent()
        let stamp = "state-aside-\(format.string(from: now))"
        var aside = parent.appending(path: stamp, directoryHint: .isDirectory)
        var n = 2
        while fm.fileExists(atPath: aside.path) {
            aside = parent.appending(path: "\(stamp)-\(n)", directoryHint: .isDirectory)
            n += 1
        }
        try fm.moveItem(at: stateDir, to: aside)
        try fm.createDirectory(at: stateDir, withIntermediateDirectories: true)
        return aside
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

    /// The same envelope, as read: one entry that does not decode is dropped
    /// and reported, not allowed to take the others with it. A `workspaces`
    /// key that is missing or not an array is still a decode failure — there
    /// is no list to keep, and `{}` is not a first launch.
    private struct DecodedEnvelope: Decodable {
        var workspaces: [WorkspaceDefinition]
        var activeId: UUID?

        enum CodingKeys: String, CodingKey { case workspaces, activeId }

        init(from decoder: Decoder) throws {
            let notes = decoder.userInfo[.workspaceDecodeNotes] as? WorkspaceDecodeNotes
            let c = try decoder.container(keyedBy: CodingKeys.self)
            var list = try c.nestedUnkeyedContainer(forKey: .workspaces)
            var workspaces: [WorkspaceDefinition] = []
            while !list.isAtEnd {
                let index = list.currentIndex
                let entry = try list.decode(Lossy<WorkspaceDefinition>.self)
                if let value = entry.value {
                    workspaces.append(value)
                } else {
                    notes?.rejected("entry \(index): \(describe(entry.error))")
                }
            }
            self.workspaces = workspaces
            do {
                self.activeId = try c.decodeIfPresent(UUID.self, forKey: .activeId)
            } catch {
                self.activeId = nil
                notes?.repaired("activeId is not a UUID; the first workspace will be active")
            }
        }
    }

    /// Decodes `Value` without ever throwing, so an unkeyed container moves
    /// past a bad element instead of failing (a thrown `decode` leaves the
    /// container's index where it was). The error is kept for the report.
    private struct Lossy<Value: Decodable>: Decodable {
        let value: Value?
        let error: (any Error)?
        init(from decoder: Decoder) {
            do {
                value = try Value(from: decoder)
                error = nil
            } catch {
                value = nil
                self.error = error
            }
        }
    }

    /// What was found at `definitionsFile`.
    enum LoadOutcome {
        /// No file: the first launch. Seeding a default and writing it is right.
        case absent
        /// A list. `repairs` are fields that took a default; `rejected` are
        /// entries that could not be used (`save` keeps a copy of the original
        /// file before the first write when there are any).
        case loaded(workspaces: [WorkspaceDefinition], activeId: UUID?, repairs: [String], rejected: [String])
        /// The file exists and could not be read or decoded — an I/O error, an
        /// empty or truncated file, no usable entry. It, and every state
        /// directory it might name, must be left exactly as they are.
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

        let notes = WorkspaceDecodeNotes()
        let decoder = JSONDecoder()
        decoder.userInfo[.workspaceDecodeNotes] = notes
        decoder.userInfo[.workspacesRoot] = file.deletingLastPathComponent()
            .appending(path: "Workspaces", directoryHint: .isDirectory)
        let env: DecodedEnvelope
        do {
            env = try decoder.decode(DecodedEnvelope.self, from: data)
        } catch {
            return .unreadable(reason: "does not decode: \(describe(error))")
        }
        if env.workspaces.isEmpty, !notes.rejected.isEmpty {
            return .unreadable(reason: "has no usable entry (\(notes.rejected.joined(separator: "; ")))")
        }
        return .loaded(workspaces: env.workspaces, activeId: env.activeId,
                       repairs: notes.repairs, rejected: notes.rejected)
    }

    /// Atomically writes the workspace list + active id — **unless the file
    /// on disk exists and cannot be read**, in which case nothing is written
    /// and the refusal is logged. That is the guarantee: a `workspaces.json`
    /// the app cannot decode is never replaced, whatever the caller thinks
    /// the list is. If the file decoded with entries rejected, a copy of it
    /// is kept beside it (`workspaces.json.rejected-<time>`) before the first
    /// write, so the bytes of the entry that was dropped are not lost either.
    /// Returns whether the file was written.
    @discardableResult
    static func save(_ workspaces: [WorkspaceDefinition], activeId: UUID?) -> Bool {
        save(workspaces, activeId: activeId, to: definitionsFile)
    }

    @discardableResult
    static func save(_ workspaces: [WorkspaceDefinition], activeId: UUID?, to file: URL) -> Bool {
        switch load(from: file) {
        case .absent:
            break
        case .loaded(_, _, _, let rejected):
            if !rejected.isEmpty, !keepCopy(of: file) { return false }
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

    /// Copies `file` to `<file>.rejected-<time>` before it is overwritten.
    /// False, with a log line, if the copy could not be made — then the write
    /// must not happen either.
    private static func keepCopy(of file: URL) -> Bool {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "")
        let copy = file.deletingLastPathComponent()
            .appending(path: file.lastPathComponent + ".rejected-" + stamp)
        do {
            try FileManager.default.copyItem(at: file, to: copy)
            logger.log("workspaces.json: an entry was rejected; the original file is kept as \(copy.lastPathComponent)")
            return true
        } catch {
            refuseWrite(because: "its original, with a rejected entry, could not be copied aside (\(describe(error)))")
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


