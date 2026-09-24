// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

// Stand-in for TSNet/Logging.swift's `logger` (which imports TailscaleKit),
// so the REAL TSNet/SocksLogProxy.swift compiles on the host for
// scripts/test-socks-relay-policy.sh. Keeps the lines, so the tests can read
// what the relay said. Thread-safe: the relay logs from its own queue.

import Foundation

nonisolated final class LogStub: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    nonisolated func log(_ message: String) {
        lock.lock()
        stored.append(message)
        lock.unlock()
    }

    nonisolated var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

nonisolated let logger = LogStub()
