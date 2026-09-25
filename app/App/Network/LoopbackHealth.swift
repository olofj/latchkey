// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

//
//  LoopbackHealth.swift
//  Latchkey
//
//  How the app tells a working tsnet loopback from a broken one (F16).
//
//  The loopback breaks in two ways. A refused one (a closed or defuncted
//  listener) fails every LocalAPI request with -1004 or -1005 at once, and
//  `isLocalLoopbackConnectionFailure` has recognised that since R14. A
//  silent one accepts every connection and never answers. TailscaleKit's
//  requests carry a 60 s timeout that no caller can change, so each caller
//  used to wait out the whole minute and then get a -1001 that nothing
//  treated as a fault. The picker then read "Searching…" for over a minute.
//
//  So a status request is bounded (`bounded`, `statusBound`). An abandoned
//  one is a `LoopbackStatusTimeout`, a signal of its own, and two in a row
//  replace the loopback (`LoopbackStallCount`). It is not a -1001: the IPN
//  bus's long-poll dies with -1001 every idle minute by design, and reading
//  that as a loopback failure would restart the loopback every minute.
//
//  Foundation only, so the host tests (scripts/test-loopback-stalls.swift)
//  compile it without TailscaleKit.
//

import Foundation

/// A status request that was abandoned at its bound (F16). Distinct from
/// any NSURLError on purpose: the bus's idle -1001 is routine, this is not.
nonisolated struct LoopbackStatusTimeout: Error {}

nonisolated enum LoopbackHealth {
    /// How long a status request may take on a path something is waiting on.
    /// Loopback answers in milliseconds; the bound covers a busy node actor.
    /// Chosen, not measured (F16 §8): answers slower than `slowAnswer` are
    /// logged so device use can show whether it is tight.
    static let statusBound: Duration = .seconds(3)
    static let slowAnswer: Duration = .milliseconds(500)

    /// `operation`, or `LoopbackStatusTimeout` once `bound` has passed.
    ///
    /// The loser is cancelled but NOT awaited. A task group would await it,
    /// and the one thing a silent loopback is sure to produce is an operation
    /// that does not finish promptly: a call queued on a busy node actor
    /// does not see cancellation until the actor gets to it. URLSession's
    /// async API does honour cancellation, so an abandoned request is torn
    /// down rather than left to run out its 60 s.
    static func bounded<T: Sendable>(
        within bound: Duration,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let outcome = FirstOutcome<T>()
        let work = Task { try await operation() }
        let timer = Task {
            // Cancelled means the operation finished first.
            do { try await Task.sleep(for: bound) } catch { return }
            outcome.finish(.failure(LoopbackStatusTimeout()))
            work.cancel()
        }
        Task {
            let result = await work.result
            timer.cancel()
            outcome.finish(result)
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { outcome.install($0) }
        } onCancel: {
            work.cancel()
            timer.cancel()
            outcome.finish(.failure(CancellationError()))
        }
    }

    /// Whether `error` is a LocalAPI request that could not reach the
    /// loopback listener at all: refused (-1004) or cut (-1005), to a
    /// loopback address.
    ///
    /// **-1001 is deliberately not here** (F16 §1.2). The IPN bus's long-poll
    /// has no keep-alive, so URLSession's 60 s timeout kills it with -1001
    /// every idle minute, and this function classifies the bus's errors too
    /// (`TSNetManager.scheduleBusRestart`). Adding it would restart the
    /// loopback every idle minute. A loopback that accepts and never answers
    /// is caught by `LoopbackStatusTimeout` instead, which only the bounded
    /// status requests raise.
    static func isLocalLoopbackConnectionFailure(_ error: Error) -> Bool {
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain,
              (ns.code == NSURLErrorCannotConnectToHost
                || ns.code == NSURLErrorNetworkConnectionLost)
        else { return false }
        let rawURL = (ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL)?.absoluteString ?? ""
        guard let host = URL(string: rawURL)?.host()?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }
}

/// Consecutive abandoned status requests, from any caller (F16 §4.1).
///
/// Two strikes, not one: a single slow answer, such as the node actor busy in
/// `restartLoopback` or a GC pause, must not replace a working listener.
/// Replacing it changes the SOCKS credential and the relay, which is not
/// free. `sessionCheckUnanswered`'s "twice in a row" is the same reasoning.
nonisolated struct LoopbackStallCount {
    static let strikes = 2
    private(set) var consecutive = 0

    /// Records an abandoned request. Returns its place in the run, and whether
    /// it is the one that calls for replacing the loopback; if so the count
    /// starts over.
    mutating func abandoned() -> (strike: Int, recover: Bool) {
        consecutive += 1
        let strike = consecutive
        guard strike >= Self.strikes else { return (strike, false) }
        consecutive = 0
        return (strike, true)
    }

    /// Records an answered request: the loopback carries bytes.
    mutating func answered() {
        consecutive = 0
    }
}

/// The first of several racers to finish resumes the continuation; the rest
/// are dropped. It may finish before the continuation is installed.
nonisolated private final class FirstOutcome<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var result: Result<T, Error>?

    func install(_ continuation: CheckedContinuation<T, Error>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func finish(_ result: Result<T, Error>) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}
