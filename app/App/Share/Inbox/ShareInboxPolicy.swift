// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

//
//  ShareInboxPolicy.swift
//  Latchkey
//
//  What the share inbox admits and what it forgets (F3 §4.3), as data. Pure,
//  so scripts/test-share.sh checks it on the host.
//
//  The limits are the gateway's where it has one: a document over 50 MB is
//  refused at capture, before any byte is copied, because the gateway would
//  refuse it anyway (`_MAX_UPLOAD_BYTES`, handlers/files.py in 0.6.0). The
//  inbox's own caps keep a phone that never opens the app from filling up.
//
//  The extension allowlist is ADVISORY. It mirrors the gateway's, so the
//  owner hears early that `.bin` will probably be refused; the gateway's own
//  answer is the one that counts, so a drift between versions costs a
//  clearer message, never a share refused here that the gateway would take.
//

import Foundation

nonisolated enum ShareInboxPolicy {
    static let maxDocumentBytes: Int64 = 50 * 1024 * 1024
    static let maxItems = 20
    static let maxInboxBytes: Int64 = 200 * 1024 * 1024
    static let lifetime: TimeInterval = 7 * 24 * 3600
    /// A `.staging` directory this old is a crashed writer's.
    static let stagingLifetime: TimeInterval = 10 * 60
    /// Automatic retries of an unreachable gateway, one per foreground.
    static let maxAutomaticAttempts = 5

    /// The gateway's upload allowlist: `_ALLOWED_IMAGE_EXT | _ALLOWED_TEXT_EXT
    /// | _ALLOWED_DOC_EXT` and the video set, handlers/files.py:984-1040 in
    /// 0.6.0, with the five text types 0.7.0 added. The union: an advisory
    /// must not warn about what either version takes.
    static let gatewayExtensions: Set<String> = [
        // images
        ".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".svg",
        // text (0.7.0 adds .text, .xwiki, .jsonl, .drawio, .tsv)
        ".txt", ".md", ".json", ".excalidraw", ".har", ".yaml", ".yml", ".xml", ".csv", ".log",
        ".py", ".js", ".ts", ".tsx", ".jsx", ".html", ".css", ".sh", ".bash", ".rb", ".go", ".rs",
        ".java", ".c", ".cpp", ".h", ".hpp", ".text", ".xwiki", ".jsonl", ".drawio", ".tsv",
        // documents and archives
        ".pdf", ".doc", ".docx", ".xls", ".xlsx", ".ppt", ".pptx", ".odt", ".ods", ".odp", ".rtf",
        ".zip", ".tar", ".gz",
        // video (the gateway's own, larger limit does not apply here: 50 MB)
        ".mp4", ".m4v", ".mov", ".webm",
    ]

    enum Refusal: Equatable {
        case tooLarge(byteCount: Int64)
        case inboxFull(waiting: Int)
    }

    enum Admission: Equatable {
        /// Admitted; `advisory` is a warning to show, not a refusal.
        case admitted(advisory: String?)
        case refused(Refusal)
    }

    /// Whether a new item may enter an inbox that already holds `inboxCount`
    /// items of `inboxBytes` together. `fileExtension` is "" for a link or
    /// text.
    static func admit(byteCount: Int64, fileExtension: String,
                      inboxCount: Int, inboxBytes: Int64) -> Admission {
        if byteCount > maxDocumentBytes { return .refused(.tooLarge(byteCount: byteCount)) }
        if inboxCount >= maxItems || inboxBytes + byteCount > maxInboxBytes {
            return .refused(.inboxFull(waiting: inboxCount))
        }
        let ext = fileExtension.lowercased()
        if !ext.isEmpty, !gatewayExtensions.contains(ext) {
            return .admitted(advisory: "The gateway may refuse \(ext) files.")
        }
        return .admitted(advisory: nil)
    }

    static func sentence(for refusal: Refusal) -> String {
        switch refusal {
        case .tooLarge:
            return "Files over 50 MB can't be sent — that's the gateway's limit."
        case .inboxFull(let waiting):
            return "Latchkey has \(waiting) shares waiting. Open it to send them before sharing more."
        }
    }

    /// The items the sweep removes: older than `lifetime`. An item of a newer
    /// version is not the sweep's to judge and never reaches it.
    static func sweep(items: [(id: String, createdAt: Date)], now: Date) -> [String] {
        items.filter { now.timeIntervalSince($0.createdAt) > lifetime }.map(\.id)
    }

    /// The staging directories the sweep removes: a writer that crashed.
    static func sweepStaging(_ entries: [(name: String, modifiedAt: Date)], now: Date) -> [String] {
        entries.filter { now.timeIntervalSince($0.modifiedAt) > stagingLifetime }.map(\.name)
    }

    /// Whether a failed item is retried by itself on the next foreground:
    /// only when nothing was wrong with it but the path to the gateway.
    static func retriesAutomatically(_ item: ShareItem) -> Bool {
        item.state != .failed
            || (item.lastError == ShareOutcome.unreachableCode && item.attempts < maxAutomaticAttempts)
    }
}
