// Copyright (c) Tailscale Inc & contributors
// SPDX-License-Identifier: BSD-3-Clause

// Stand-ins for the four symbols App/Workspace/WorkspaceStore.swift reads
// from the rest of the app, so the REAL store can be compiled and run on the
// host without TailscaleKit, UIKit or a simulator. Values mirror the app's.

import Foundation

/// TailscaleKit's `kDefaultControlURL` (TailscaleNode.swift).
let kDefaultControlURL = "https://controlplane.tailscale.com"

/// App/Browser/HomePage.swift: "" means no gateway chosen yet.
enum HomePage {
    static let defaultURL = ""
}

/// TSNet/TSNetManager.swift: the test-only ephemeral launch flag, off here.
enum TSNetManager {
    static func launchEphemeral() -> Bool { false }
}

/// TSNet/Logging.swift: the store logs refusals; the test collects them.
struct Logger {
    nonisolated(unsafe) static var lines: [String] = []
    func log(_ message: String) {
        Logger.lines.append(message)
        print("  log: \(message)")
    }
}
let logger = Logger()
