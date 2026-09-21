// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

//
//  BackupExclusion.swift
//  Latchkey
//
//  Keeps the app's secrets out of iCloud and Finder backups and out of device
//  migration (revision R5, review finding M1).
//
//  Two secrets live on disk, and upstream excluded neither:
//
//  - the tsnet node's private keys, in the workspace state directory under
//    Application Support;
//  - KiroCrew's 30-day refresh cookie, in WebKit's website data store.
//
//  Restored onto a second device, the first would give two phones one tailnet
//  identity, and the second a live dashboard session nobody minted for that
//  device. The right behaviour after a restore is a fresh start — a new node
//  login and a new token — which is exactly what excluding them produces.
//
//  The attribute is set on directories, which excludes everything created
//  inside them later. It is re-applied at every launch because it is cheap
//  and idempotent, and because a directory recreated by something else (a
//  wipe, WebKit's own housekeeping) would otherwise silently lose it.
//
//  The Keychain is not used anywhere in this app, TailscaleKit or libtailscale.
//  Anything that ever adds a Keychain item must use
//  kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly for the same reason (R5).
//

import Foundation

enum BackupExclusion {
    /// Directories whose contents must never be backed up, relative to the
    /// app container's Library. Created if missing so the attribute is in
    /// place before anything is written into them.
    nonisolated static let libraryDirectories = [
        "WebKit",        // identifier-based WKWebsiteDataStores, incl. the refresh cookie
        "Cookies",       // the default cookie store
        "HTTPStorages",  // URLSession's cookie and HSTS storage for this app
    ]

    /// Applies the exclusion to the app's data root and the WebKit/cookie
    /// directories. Returns a one-line summary for the log.
    @discardableResult
    static func apply(appSupportRoot: URL) -> String {
        var targets = [appSupportRoot]
        if let library = FileManager.default.urls(for: .libraryDirectory,
                                                  in: .userDomainMask).first {
            targets += libraryDirectories.map {
                library.appending(path: $0, directoryHint: .isDirectory)
            }
        }
        var failures: [String] = []
        for dir in targets {
            if let error = exclude(dir) {
                failures.append("\(dir.lastPathComponent): \(error)")
            }
        }
        return failures.isEmpty
            ? "backup exclusion applied to \(targets.map(\.lastPathComponent).joined(separator: ", "))"
            : "backup exclusion FAILED for \(failures.joined(separator: "; "))"
    }

    /// Creates `dir` if needed and marks it excluded. Returns an error
    /// description, or nil on success.
    nonisolated static func exclude(_ dir: URL) -> String? {
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var url = dir
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try url.setResourceValues(values)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
