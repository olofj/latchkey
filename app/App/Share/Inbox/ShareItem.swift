// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

//
//  ShareItem.swift
//  Latchkey
//
//  One thing shared into Latchkey and not yet confirmed by a gateway (F3
//  §4.3): its `item.json` in the inbox. Pure, so scripts/test-share.sh checks
//  the round trip on the host.
//
//  Written by whatever captured it (the URL handler, the App Intent -- and,
//  if stage 2 is ever built, the share extension) and read only by the app.
//  Nothing in it is ever logged but `id`, `kind`, `byteCount`, `source` and
//  the filename's extension (D1).
//

import Foundation

nonisolated struct ShareItem: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case link, text, document }
    enum Source: String, Codable, Sendable { case urlScheme, intent, `extension` }
    enum State: String, Codable, Sendable { case pending, sending, failed }

    /// The version this build writes and reads. A higher one is left where it
    /// is, untouched and undelivered (F3 §5): a newer build wrote it.
    static let currentVersion = 1

    var version: Int = ShareItem.currentVersion
    var id: String
    var kind: Kind
    var url: String?
    var title: String?
    var text: String?
    var note: String?
    /// Sanitised to `[A-Za-z0-9_.-]`, as the gateway does with the part name.
    var filename: String?
    var utType: String?
    var byteCount: Int64
    var createdAt: Date
    var source: Source
    var state: State = .pending
    var attempts: Int = 0
    var lastError: String?
    var lastAttemptAt: Date?

    /// The filename's extension, lowercased, with the dot (`.pdf`), or "".
    var fileExtension: String {
        guard let filename, let dot = filename.lastIndex(of: "."), dot != filename.startIndex else { return "" }
        return filename[dot...].lowercased()
    }

    /// `name` reduced to what the gateway would keep: every character outside
    /// `[A-Za-z0-9_.-]` becomes `_`, leading dots go (no hidden files), and an
    /// empty result is `file`.
    static func sanitisedFilename(_ name: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")
        var out = String(name.map { allowed.contains($0) ? $0 : "_" })
        while out.hasPrefix(".") { out.removeFirst() }
        if out.count > 128 {
            // Keep the extension: the gateway decides by it.
            let ext = out.lastIndex(of: ".").map { String(out[$0...]) } ?? ""
            out = String(out.prefix(128 - min(ext.count, 16))) + ext.suffix(16)
        }
        return out.isEmpty ? "file" : out
    }

    enum Decoded: Equatable {
        case item(ShareItem)
        /// A newer build's item: leave it alone.
        case newerVersion(Int)
        case unreadable
    }

    private struct Header: Decodable { let version: Int? }

    static func decode(_ data: Data) -> Decoded {
        // Dates as Foundation's own seconds, so a round trip is exact.
        let decoder = JSONDecoder()
        guard let header = try? decoder.decode(Header.self, from: data) else { return .unreadable }
        let version = header.version ?? 0
        if version > currentVersion { return .newerVersion(version) }
        guard version == currentVersion, let item = try? decoder.decode(ShareItem.self, from: data)
        else { return .unreadable }
        return .item(item)
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}
