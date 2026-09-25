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
//  Stage 1 writes only to the app's own container
//  (`WorkspaceStore.appSupportDir/ShareInbox/`), which needs no App Group and
//  no entitlement. `locations` is a list so that stage 2's group container
//  can be put in front of it without a migration (F3 §4.3, §8 Q1).
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

    /// Where the app looks, in drain order. Stage 1: the app's own container.
    static func locations(appSupport: URL) -> [URL] {
        [appSupport.appending(path: "ShareInbox", directoryHint: .isDirectory)]
    }

    /// Where this process writes: the first location.
    static func writeLocation(appSupport: URL) -> ShareInboxStore {
        ShareInboxStore(root: locations(appSupport: appSupport)[0])
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
    @discardableResult
    func add(_ item: ShareItem, payloadFile: URL? = nil, payloadData: Data? = nil) throws -> String? {
        try prepare()
        let waiting = summary()
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
