// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

//
//  ShareMirror.swift
//  Latchkey
//
//  The session mirror (F18 §6.1): what the share sheet's drop-down needs,
//  written by the app into the group container after every successful
//  listing, so the Shortcut's `destination` parameter can offer sessions
//  while the app is not running. Titles and folder names only -- no URL,
//  note, content or credential (D1 is unaffected: nothing leaves the
//  device, and the container is Latchkey's own).
//
//  Shared source, like the inbox: Foundation only, compiled into both
//  targets, so it is `nonisolated` throughout. The app is its only writer;
//  the file is `<container>/Library/Application Support/ShareMirror/
//  mirror.json`, written atomically and excluded from backup.
//
//  The mirror only ever OFFERS. A key taken from it is posted only after
//  the app re-lists and finds it (F3 §4.5's trap; `ShareDelivery`).
//

import Foundation

/// One session the owner can share to, as the sidebar shows it.
nonisolated struct ShareSession: Codable, Identifiable, Equatable, Sendable {
    let key: String
    let title: String
    let folder: String?
    let running: Bool
    let queueDepth: Int
    let lastActivity: Double
    var id: String { key }

    /// What the dashboard's sidebar shows: `surface` (a copy of `mode`) of
    /// "" or "orchestrator" (0.7.0's filter; 0.6.0 also showed "crew"), and
    /// never a `member-*` key, which the gateway reserves (409). Newest
    /// activity first.
    static func list(from slots: [[String: Any]], folders: [String: String]) -> [ShareSession] {
        slots.compactMap { s -> ShareSession? in
            guard let key = s["key"] as? String, !key.isEmpty, !key.hasPrefix("member-") else { return nil }
            let surface = (s["surface"] as? String) ?? (s["mode"] as? String) ?? ""
            guard surface == "" || surface == "orchestrator" else { return nil }
            let title = (s["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? key
            return ShareSession(key: key, title: title,
                                folder: (s["folder_id"] as? String).flatMap { folders[$0] },
                                running: (s["running"] as? Bool) ?? false,
                                queueDepth: (s["queue_depth"] as? Int) ?? 0,
                                lastActivity: (s["last_activity_ts"] as? Double)
                                    ?? Double((s["last_activity_ts"] as? Int) ?? 0))
        }
        .sorted { $0.lastActivity > $1.lastActivity }
    }

    /// The share order (issue #5): the sessions shared to, most recent
    /// share first, then the rest by the gateway's activity. Activity alone
    /// moves with every turn run anywhere, so it cannot say what the owner
    /// last shared to.
    static func shareOrdered(_ sessions: [ShareSession], sharedAt: (String) -> Date?) -> [ShareSession] {
        sessions.enumerated().sorted { a, b in
            switch (sharedAt(a.element.key), sharedAt(b.element.key)) {
            case let (x?, y?) where x != y: return x > y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return a.offset < b.offset
            }
        }.map(\.element)
    }

    /// The keys whose title and folder another session on the same gateway
    /// also has: their rows would read identically, so they name the key.
    static func ambiguousKeys(_ sessions: [ShareSession]) -> Set<String> {
        let groups = Dictionary(grouping: sessions) { "\($0.title)\u{0}\($0.folder ?? "")" }
        return Set(groups.values.filter { $0.count > 1 }.flatMap { $0.map(\.key) })
    }
}

nonisolated struct ShareMirror: Codable, Equatable, Sendable {
    static let currentVersion = 1
    /// Older than this, a gateway's list is not offered (F18 §9 Q6: 24 h).
    static let staleAfter: TimeInterval = 24 * 3600

    struct Destination: Codable, Equatable, Sendable {
        var slotKey: String
        var slotTitle: String?
        var at: Date
    }

    struct Gateway: Codable, Equatable, Sendable {
        var origin: String
        /// The host, and its port when the origin has one, for the drop-down.
        var label: String
        var fetchedAt: Date
        var sessions: [ShareSession]
        var lastDestination: Destination?
        /// When each listed session was last shared to (issue #5). Optional
        /// so a mirror written before it still decodes; pruned to the
        /// listed sessions at every listing, which is its only bound.
        var sharedAt: [String: Date]?

        func isStale(now: Date) -> Bool { now.timeIntervalSince(fetchedAt) > ShareMirror.staleAfter }

        /// A mirror from before `sharedAt` still knows its last destination.
        func sharedAt(_ key: String) -> Date? {
            sharedAt?[key] ?? (lastDestination?.slotKey == key ? lastDestination?.at : nil)
        }
    }

    /// `host[:port]`: two gateways on one host differ only by port, so a
    /// label without it can name two origins at once.
    static func hostLabel(origin: String) -> String {
        guard let url = URL(string: origin), let host = url.host else { return origin }
        return url.port.map { "\(host):\($0)" } ?? host
    }

    var version: Int = ShareMirror.currentVersion
    /// The gateway the app shows now.
    var current: String?
    var gateways: [Gateway] = []

    func gateway(_ origin: String) -> Gateway? { gateways.first { $0.origin == origin } }

    /// Replaces `origin`'s entry with a fresh listing and makes it current.
    mutating func record(origin: String, label: String, sessions: [ShareSession], at now: Date) {
        let previous = gateway(origin)
        let listed = Set(sessions.map(\.key))
        let shared = previous?.sharedAt?.filter { listed.contains($0.key) }
        gateways.removeAll { $0.origin == origin }
        gateways.insert(Gateway(origin: origin, label: label, fetchedAt: now, sessions: sessions,
                                lastDestination: previous?.lastDestination,
                                sharedAt: shared?.isEmpty == false ? shared : nil), at: 0)
        current = origin
    }

    mutating func remember(origin: String, _ destination: Destination) {
        guard let i = gateways.firstIndex(where: { $0.origin == origin }) else { return }
        gateways[i].lastDestination = destination
        let was = gateways[i].sharedAt?[destination.slotKey] ?? .distantPast
        gateways[i].sharedAt = (gateways[i].sharedAt ?? [:])
            .merging([destination.slotKey: max(was, destination.at)]) { $1 }
    }

    /// Drops every gateway not in `origins` (F18 §6.1: a gateway's entry
    /// goes when the gateway is removed from the workspace). Returns whether
    /// anything changed.
    @discardableResult
    mutating func retain(origins: [String]) -> Bool {
        let keep = Set(origins)
        let before = gateways.count
        gateways.removeAll { !keep.contains($0.origin) }
        if let c = current, !keep.contains(c) { current = nil }
        return gateways.count != before
    }

    // MARK: - What the drop-down sees

    /// Why the list is empty, in the owner's words (F18 §5), or nil when
    /// `offered` has something to show.
    static func emptyReason(_ mirror: ShareMirror?, now: Date) -> String? {
        guard let mirror, !mirror.gateways.isEmpty else {
            return "Open Latchkey once so it can list your sessions."
        }
        let fresh = mirror.gateways.filter { !$0.isStale(now: now) }
        guard !fresh.isEmpty else {
            let newest = mirror.gateways.map(\.fetchedAt).max() ?? .distantPast
            let hours = max(1, Int(now.timeIntervalSince(newest) / 3600))
            return "Latchkey's session list is \(hours) h old. Open Latchkey to refresh it."
        }
        guard fresh.contains(where: { !$0.sessions.isEmpty }) else {
            let label = fresh.first { $0.origin == mirror.current }?.label ?? fresh[0].label
            return "\(label) has no sessions."
        }
        return nil
    }

    /// The gateways the drop-down offers: fresh ones, the current first.
    func offered(now: Date) -> [Gateway] {
        gateways.filter { !$0.isStale(now: now) }
            .sorted { a, b in (a.origin == current ? 0 : 1) < (b.origin == current ? 0 : 1) }
    }

    /// One row of the drop-down.
    struct Offer: Equatable, Sendable {
        let gateway: Gateway
        let session: ShareSession
        /// The one session shared to most recently, on any gateway.
        let isLast: Bool
        /// More than one gateway is offered: the row names its host.
        let namesGateway: Bool
        /// Another session on its gateway has the same title and folder:
        /// the row names its key.
        let namesKey: Bool
    }

    /// Every fresh gateway's sessions as ONE list (issue #5): the sessions
    /// shared to, most recent share first, whichever gateway they are on;
    /// then the rest by the gateway's activity. Which gateway the app last
    /// listed does not move anything: the foreground re-list would otherwise
    /// outrank a share that went to another gateway.
    func offers(now: Date) -> [Offer] {
        let fresh = offered(now: now)
        let several = fresh.count > 1
        let pairs = fresh.flatMap { g in g.sessions.map { (g, $0) } }
        let sorted = pairs.enumerated().sorted { a, b in
            let (x, y) = (a.element.0.sharedAt(a.element.1.key), b.element.0.sharedAt(b.element.1.key))
            switch (x, y) {
            case let (x?, y?) where x != y: return x > y
            case (.some, nil): return true
            case (nil, .some): return false
            default:
                let (p, q) = (a.element.1.lastActivity, b.element.1.lastActivity)
                return p != q ? p > q : a.offset < b.offset
            }
        }.map(\.element)
        let last = sorted.first.flatMap { $0.0.sharedAt($0.1.key) != nil ? "\($0.0.origin) \($0.1.key)" : nil }
        let ambiguous = Dictionary(uniqueKeysWithValues: fresh.map { ($0.origin, ShareSession.ambiguousKeys($0.sessions)) })
        return sorted.map { g, s in
            Offer(gateway: g, session: s, isLast: "\(g.origin) \(s.key)" == last, namesGateway: several,
                  namesKey: ambiguous[g.origin]?.contains(s.key) == true)
        }
    }

    private struct Header: Decodable { let version: Int? }

    /// nil for a file this build cannot read (absent, garbage, or a newer
    /// version: left alone, offered as nothing).
    static func decode(_ data: Data) -> ShareMirror? {
        let decoder = JSONDecoder()
        guard let header = try? decoder.decode(Header.self, from: data),
              header.version == currentVersion else { return nil }
        return try? decoder.decode(ShareMirror.self, from: data)
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}

/// The mirror on disk. Read by the app and the Shortcut's entity query,
/// written by the app alone.
nonisolated struct ShareMirrorStore: Sendable {
    let file: URL

    static let directory = "ShareMirror"
    static let fileName = "mirror.json"

    /// The group container's file when this process has the entitlement,
    /// else the app's own: the same fallback as the inbox, so a build
    /// without the App Group still offers a list to its own intent.
    static func location(appSupport: URL, groupContainer: URL?) -> URL {
        let root = groupContainer?.appending(path: "Library/Application Support", directoryHint: .isDirectory)
            ?? appSupport
        return root.appending(path: directory, directoryHint: .isDirectory).appending(path: fileName)
    }

    static func app(appSupport: URL) -> ShareMirrorStore {
        let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: ShareInboxStore.appGroup)
        return ShareMirrorStore(file: location(appSupport: appSupport, groupContainer: group))
    }

    func load() -> ShareMirror? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return ShareMirror.decode(data)
    }

    func save(_ mirror: ShareMirror) throws {
        let dir = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = BackupExclusion.exclude(dir)
        try mirror.encoded().write(to: file, options: .atomic)
    }

    /// Loads, applies `change`, and saves when it changed anything.
    func update(_ change: (inout ShareMirror) -> Void) {
        var mirror = load() ?? ShareMirror()
        let before = mirror
        change(&mirror)
        guard mirror != before else { return }
        try? save(mirror)
    }

    /// The test hook `-UITestResetShare`.
    func removeAll() {
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }
}
