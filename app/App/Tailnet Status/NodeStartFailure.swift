// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

//
//  NodeStartFailure.swift
//  Latchkey
//
//  F8: a node that cannot start is a screen, not a crash. This is the pure
//  part — what the screen says and when the next attempt is — so the host
//  tests (scripts/test-node-start-failure.swift) can pin it without a
//  simulator. `TSNetManager` feeds it; `StatusView` shows it (G7).
//

import Foundation

/// Why there is no node, as the gate shows it (F8 §2, G7). In memory only: a
/// failure that survived a relaunch would be a stale claim about a node that
/// might start fine this time (F8 §5).
nonisolated struct NodeStartFailure: Equatable, Sendable {
    enum Stage: Equatable, Sendable {
        /// Process logging could not be set up, so no node is created at all
        /// (F8 §4.6): its filch is what redacts tsnet's Go stderr.
        case logging
        /// Creating or bringing up the node threw.
        case node
    }

    let stage: Stage
    /// Nil when the error carried none and tsnet's message names none either.
    let errnoValue: Int32?
    /// tsnet's own words, for the log and Logs.
    let message: String
    /// Consecutive failures in the current schedule, from 1.
    let attempt: Int
    /// Nil when the attempts are exhausted, and always for `.logging`: a
    /// countdown over a condition that will not clear by itself is G2's lie.
    let nextRetryIn: Duration?
    let failedAt: Date

    static let title = "Latchkey can't start its Tailscale node."
    static let nothingDeleted = "Nothing has been deleted. Your node's identity is still on this device."

    /// F8 §4.3: five retries, doubling from 1 s, then none. The shape of the
    /// page's own reconnect, so the product has one backoff idiom.
    static let retryDelays: [Duration] = [1, 2, 4, 8, 16].map { .seconds($0) }

    /// The wait before the next attempt after the `attempt`th consecutive
    /// failure, or nil once the schedule is spent.
    static func retryDelay(afterFailure attempt: Int) -> Duration? {
        guard attempt >= 1, attempt <= retryDelays.count else { return nil }
        return retryDelays[attempt - 1]
    }

    init(stage: Stage, errnoValue: Int32?, message: String, attempt: Int, failedAt: Date = Date()) {
        self.stage = stage
        // TsnetStart returns -1 for every Go error (`recErr`), so a real
        // failure arrives with no errno and the cause is only in the text.
        self.errnoValue = errnoValue ?? Self.errno(inMessage: message)
        self.message = message
        self.attempt = attempt
        self.nextRetryIn = stage == .logging ? nil : Self.retryDelay(afterFailure: attempt)
        self.failedAt = failedAt
    }

    /// The one sentence on screen (F8 §2). The raw errno and message go to
    /// the log, never only this.
    var cause: String {
        if stage == .logging {
            return "Latchkey can't open its own log files, so it won't start a node until that is fixed."
        }
        switch errnoValue {
        case EACCES, EPERM:
            return "Its files can't be opened. This usually means the app's storage permissions changed."
        case ENOSPC:
            return "This device is out of storage. Free some space and it will start."
        case EADDRINUSE:
            return "A previous run is still shutting down."
        default:
            let name = errnoValue.map { " (\(Self.errnoName($0)))" } ?? ""
            return "Tailscale reported: \(message)\(name)."
        }
    }

    /// Go's error strings for the errnos the screen names (`syscall.Errno`'s
    /// text, which is strerror's, lowercased).
    static func errno(inMessage message: String) -> Int32? {
        let text = message.lowercased()
        let known: [(String, Int32)] = [
            ("permission denied", EACCES),
            ("operation not permitted", EPERM),
            ("no space left on device", ENOSPC),
            ("address already in use", EADDRINUSE),
        ]
        return known.first { text.contains($0.0) }?.1
    }

    static func errnoName(_ value: Int32) -> String {
        switch value {
        case EACCES: return "EACCES"
        case EPERM: return "EPERM"
        case ENOSPC: return "ENOSPC"
        case EADDRINUSE: return "EADDRINUSE"
        case EIO: return "EIO"
        case ENOENT: return "ENOENT"
        case EBADF: return "EBADF"
        case EINVAL: return "EINVAL"
        default: return "errno \(value)"
        }
    }

    /// For `-UITestNodeStartFails` (F8 §6.1): a name or a number.
    static func errno(named name: String) -> Int32? {
        switch name.uppercased() {
        case "EACCES": return EACCES
        case "EPERM": return EPERM
        case "ENOSPC": return ENOSPC
        case "EADDRINUSE": return EADDRINUSE
        case "EIO": return EIO
        default: return Int32(name)
        }
    }
}

/// The attempt counter and the current failure, kept together so the rule
/// "cleared only by success" lives in one place a host test can drive.
nonisolated struct NodeStartTracker: Sendable {
    private(set) var failure: NodeStartFailure?
    private var consecutive = 0

    /// Records a failed attempt and returns what to show.
    mutating func failed(stage: Stage, errnoValue: Int32?, message: String,
                         at date: Date = Date()) -> NodeStartFailure {
        consecutive += 1
        let f = NodeStartFailure(stage: stage, errnoValue: errnoValue, message: message,
                                 attempt: consecutive, failedAt: date)
        failure = f
        return f
    }

    /// A node exists: the only event that clears the failure.
    mutating func succeeded() {
        consecutive = 0
        failure = nil
    }

    /// The owner tapped Try now, or came back to the app: new information, so
    /// a fresh schedule (F8 §4.3). The failure stays on screen until a start
    /// actually succeeds.
    mutating func restartSchedule() {
        consecutive = 0
    }

    typealias Stage = NodeStartFailure.Stage
}
