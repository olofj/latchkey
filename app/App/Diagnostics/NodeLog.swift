// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

//
//  NodeLog.swift
//  Latchkey
//
//  Reads tsnet's own log (PLAN M8.3, revision R29): the local, capped files
//  the vendored libtailscale writes under the app's Logs directory
//  (latchkey_locallog.go), each with one rotated predecessor (`.1`).
//  Foundation only, so scripts/test-diagnostics.sh compiles it on the host.
//
//  Every line is redacted again on the way out (`LogRedaction.scrub`): the
//  file holds what tsnet printed, including a Tailscale login link when the
//  node needs one. Nothing here leaves the device (D1) — except what the user
//  chooses to copy.
//

import Foundation

enum NodeLog {
    enum Source: String, CaseIterable {
        /// tsnet's own lines: magicsock, DERP, control, the loopback listener.
        case tsnet = "tsnet.log"
        /// The process's raw stderr, as logtail replays it: a Go panic from
        /// the previous run. Not kept at all in launches by Xcode or XCTest,
        /// where it is a mirror of the unified log (latchkey_locallog.go).
        case stderr = "stderr.log"
    }

    /// The files for `source` in `dir`, oldest first: `<name>.1`, then
    /// `<name>`.
    nonisolated static func files(in dir: URL, source: Source = .tsnet) -> [URL] {
        [dir.appending(path: source.rawValue + ".1"), dir.appending(path: source.rawValue)]
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Deletes every source's files: a reset (R32; "everything stored on
    /// this device" includes the hostnames and peers these hold), and the
    /// `-UITestResetNodeLog` hook. tsnet's writer holds tsnet.log open, so
    /// the running process keeps writing to the unlinked inode -- nothing
    /// of this launch is kept -- and the next launch starts a fresh file.
    nonisolated static func removeFiles(in dir: URL) {
        for source in Source.allCases {
            for url in files(in: dir, source: source) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Name, size and modification time of `source`'s files: when it has not
    /// changed there is nothing new to read.
    nonisolated static func signature(in dir: URL, source: Source = .tsnet) -> [String] {
        files(in: dir, source: source).map { url in
            let a = try? FileManager.default.attributesOfItem(atPath: url.path)
            return "\(url.lastPathComponent) \((a?[.size] as? Int) ?? -1) \((a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        }
    }

    /// The last `maxLines` lines across both files, oldest first, redacted
    /// (again: the vendored writer already redacts before writing). Reads at
    /// most the last `tailBytes` of each file.
    nonisolated static func tail(in dir: URL, source: Source = .tsnet, maxLines: Int = 2000,
                                 tailBytes: Int = 512 * 1024) -> [String] {
        var lines: [Substring] = []
        for url in files(in: dir, source: source) {
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
            guard (try? handle.seek(toOffset: start)) != nil,
                  let data = try? handle.readToEnd() else { continue }
            var text = Substring(String(decoding: data, as: UTF8.self))
            if start > 0, let newline = text.firstIndex(of: "\n") {
                text = text[text.index(after: newline)...]   // a partial first line
            }
            lines.append(contentsOf: text.split(separator: "\n", omittingEmptySubsequences: true))
        }
        return lines.suffix(maxLines).map { LogRedaction.scrub(String($0)) }
    }
}
