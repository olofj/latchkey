// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

//
//  ShareInboxStore.swift
//  Latchkey
//
//  The share inbox on disk (F3 §4.3): one directory per item under
//  `ShareInbox/`, `item.json` written LAST, so an item without it does not
//  exist. A writer assembles the item under `.staging/<id>/` -- payload
//  first, then `item.json` -- and renames the directory into place: one
//  atomic rename on one volume, so a reader never sees half an item.
//
//  Two locations (F3 §4.3), drained in this order: the App Group container
//  `group.net.lixom.latchkey` (stage 2: the share extension writes there,
//  the only place both processes can see), then the app's own
//  `WorkspaceStore.appSupportDir/ShareInbox/` (stage 1, and the fallback
//  when the entitlement is absent). A process writes to the first location
//  it has; the app reads both (`ShareInbox`), so no migration is needed in
//  either direction.
//
//  Everything here is synchronous file IO and `nonisolated`: the 50 MB copy
//  is run off the main actor by the caller.
//

import Foundation

nonisolated struct ShareInboxStore: Sendable {
    let root: URL

    static let itemFile = "item.json"
    static let payloadFile = "payload"
    static let stagingDir = ".staging"

    static let appGroup = "group.net.lixom.latchkey"

    /// The inbox in the App Group container, if this process has the
    /// entitlement (`containerURL` is nil without it).
    static func groupRoot(_ container: URL?) -> URL? {
        container?.appending(path: "Library/Application Support/ShareInbox", directoryHint: .isDirectory)
    }

    /// Where the app looks, in drain order: the group container when there
    /// is one, then the app's own container.
    static func locations(appSupport: URL?, groupContainer: URL?) -> [URL] {
        [groupRoot(groupContainer),
         appSupport?.appending(path: "ShareInbox", directoryHint: .isDirectory)].compactMap { $0 }
    }

    private var fm: FileManager { .default }

    func itemDir(_ id: String) -> URL { root.appending(path: id, directoryHint: .isDirectory) }
    func payloadURL(_ id: String) -> URL { itemDir(id).appending(path: Self.payloadFile) }

    /// Creates the inbox and keeps it out of backups (R5's reasoning: shared
    /// content is transient, and a restored phone starts clean).
    func prepare() throws {
        try fm.createDirectory(at: root.appending(path: Self.stagingDir, directoryHint: .isDirectory),
                               withIntermediateDirectories: true)
        _ = BackupExclusion.exclude(root)
    }

    enum AddError: Error, Equatable {
        case refused(ShareInboxPolicy.Refusal)
        case io(String)
    }

    /// Adds `item`, with its document's bytes from `payloadFile` (copied, a
    /// clone on APFS: no bytes through memory) or `payloadData`. Admission is
    /// checked here, against what is on disk now, so every entry point gets
    /// the same caps. Returns the advisory, if any.
    /// `waiting` is the whole inbox's summary when this store is one of
    /// several (`ShareInbox`); by default, this store's own.
    @discardableResult
    func add(_ item: ShareItem, payloadFile: URL? = nil, payloadData: Data? = nil,
             waiting: (count: Int, bytes: Int64)? = nil) throws -> String? {
        try prepare()
        let waiting = waiting ?? summary()
        let admission = ShareInboxPolicy.admit(byteCount: item.byteCount, fileExtension: item.fileExtension,
                                               inboxCount: waiting.count, inboxBytes: waiting.bytes)
        guard case .admitted(let advisory) = admission else {
            if case .refused(let r) = admission { throw AddError.refused(r) }
            return nil
        }
        let staging = root.appending(path: Self.stagingDir).appending(path: item.id, directoryHint: .isDirectory)
        do {
            try? fm.removeItem(at: staging)
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            // The payload first and item.json last, then one rename: a reader
            // never sees an item whose payload is still being written.
            let payload = staging.appending(path: Self.payloadFile)
            if let payloadFile {
                try fm.copyItem(at: payloadFile, to: payload)
            } else if let payloadData {
                try payloadData.write(to: payload)
            }
            try item.encoded().write(to: staging.appending(path: Self.itemFile))
            try fm.moveItem(at: staging, to: itemDir(item.id))
        } catch {
            try? fm.removeItem(at: staging)
            throw AddError.io(String(describing: type(of: error)))
        }
        return advisory
    }

    /// Every readable item, oldest first. A newer build's item is skipped,
    /// not touched (F3 §5).
    func items() -> [ShareItem] {
        entries().compactMap { if case .item(let i) = $0.decoded { return i } else { return nil } }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// How many items wait and how many bytes they hold, newer builds' too.
    func summary() -> (count: Int, bytes: Int64) {
        let all = entries()
        let bytes = all.reduce(Int64(0)) { sum, e in
            if case .item(let i) = e.decoded { return sum + i.byteCount }
            return sum + ((try? fm.attributesOfItem(atPath: e.dir.appending(path: Self.payloadFile).path)[.size]
                           as? Int64) ?? 0)
        }
        return (all.count, bytes)
    }

    private func entries() -> [(dir: URL, decoded: ShareItem.Decoded)] {
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        return names.filter { !$0.hasPrefix(".") }.compactMap { name in
            let dir = root.appending(path: name, directoryHint: .isDirectory)
            guard let data = try? Data(contentsOf: dir.appending(path: Self.itemFile)) else { return nil }
            return (dir, ShareItem.decode(data))
        }
    }

    /// Rewrites an item's `item.json` in place (state, attempts, error).
    func update(_ item: ShareItem) throws {
        guard fm.fileExists(atPath: itemDir(item.id).path) else { return }
        try item.encoded().write(to: itemDir(item.id).appending(path: Self.itemFile), options: .atomic)
    }

    func delete(_ id: String) {
        guard !id.isEmpty, !id.contains("/"), !id.hasPrefix(".") else { return }
        try? fm.removeItem(at: itemDir(id))
    }

    /// Removes everything: the test hook `-UITestResetShare`.
    func removeAll() {
        try? fm.removeItem(at: root)
    }

    /// Items past their lifetime and staging directories a crashed writer
    /// left. Returns how many items went.
    func sweep(now: Date) -> Int {
        let old = ShareInboxPolicy.sweep(items: items().map { ($0.id, $0.createdAt) }, now: now)
        old.forEach(delete)
        let stagingRoot = root.appending(path: Self.stagingDir, directoryHint: .isDirectory)
        let staged = ((try? fm.contentsOfDirectory(atPath: stagingRoot.path)) ?? []).map { name in
            let modified = (try? fm.attributesOfItem(atPath: stagingRoot.appending(path: name).path)[.modificationDate]
                            as? Date) ?? .distantPast
            return (name: name, modifiedAt: modified)
        }
        for name in ShareInboxPolicy.sweepStaging(staged, now: now) {
            try? fm.removeItem(at: stagingRoot.appending(path: name))
        }
        return old.count
    }
}

/// Every inbox location this process can see, as one (F3 §4.3). Writes go to
/// the first; reads, updates and deletes find the item wherever it is.
nonisolated struct ShareInbox: Sendable {
    let stores: [ShareInboxStore]

    init(roots: [URL]) {
        stores = roots.map { ShareInboxStore(root: $0) }
    }

    /// The app's view: the group container (if entitled) and its own.
    static func app(appSupport: URL) -> ShareInbox {
        let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: ShareInboxStore.appGroup)
        return ShareInbox(roots: ShareInboxStore.locations(appSupport: appSupport, groupContainer: group))
    }

    var writer: ShareInboxStore { stores[0] }
    /// Whether the group container is among the locations.
    var hasGroup: Bool { stores.count > 1 }

    func prepare() throws { for s in stores { try s.prepare() } }

    @discardableResult
    func add(_ item: ShareItem, payloadFile: URL? = nil, payloadData: Data? = nil) throws -> String? {
        try writer.add(item, payloadFile: payloadFile, payloadData: payloadData, waiting: summary())
    }

    /// Oldest first, across locations; an id seen twice is read once.
    func items() -> [ShareItem] {
        var seen = Set<String>()
        return stores.flatMap { $0.items() }.filter { seen.insert($0.id).inserted }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func summary() -> (count: Int, bytes: Int64) {
        stores.map { $0.summary() }.reduce((0, 0)) { ($0.0 + $1.count, $0.1 + $1.bytes) }
    }

    private func owner(_ id: String) -> ShareInboxStore {
        stores.first { FileManager.default.fileExists(atPath: $0.itemDir(id).path) } ?? writer
    }

    func payloadURL(_ id: String) -> URL { owner(id).payloadURL(id) }
    func update(_ item: ShareItem) throws { try owner(item.id).update(item) }
    func delete(_ id: String) { for s in stores { s.delete(id) } }
    func removeAll() { for s in stores { s.removeAll() } }
    func sweep(now: Date) -> Int { stores.reduce(0) { $0 + $1.sweep(now: now) } }
}
