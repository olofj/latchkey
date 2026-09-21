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
        /// the previous run -- and, under Xcode, everything the app prints.
        case stderr = "stderr.log"
    }

    /// The files for `source` in `dir`, oldest first: `<name>.1`, then
    /// `<name>`.
    nonisolated static func files(in dir: URL, source: Source = .tsnet) -> [URL] {
        [dir.appending(path: source.rawValue + ".1"), dir.appending(path: source.rawValue)]
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The last `maxLines` lines across both files, oldest first, redacted.
    nonisolated static func tail(in dir: URL, source: Source = .tsnet, maxLines: Int = 2000) -> [String] {
        var lines: [Substring] = []
        for url in files(in: dir, source: source) {
            guard let data = try? Data(contentsOf: url) else { continue }
            let text = String(decoding: data, as: UTF8.self)
            lines.append(contentsOf: text.split(separator: "\n", omittingEmptySubsequences: true))
        }
        return lines.suffix(maxLines).map { LogRedaction.scrub(String($0)) }
    }
}
