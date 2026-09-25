// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

// Host tests for App/Network/LoopbackHealth.swift (F16 stage 1): the bound on
// a status request, the two-strike count that turns abandoned requests into a
// loopback recovery, and the classification that keeps the IPN bus's idle
// -1001 from counting as a loopback failure.
//
// Run:  make test-policy     (or: scripts/test-loopback-stalls.sh)

import Foundation

var failures = 0
var checks = 0
func expect(_ cond: Bool, _ what: String) {
    checks += 1
    if !cond { failures += 1; print("  FAIL \(what)") }
}

func seconds(since start: ContinuousClock.Instant) -> Double {
    let d = ContinuousClock.now - start
    return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
}

/// A call that never completes by itself and reports whether it was cancelled.
nonisolated final class Hung: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var continuation: CheckedContinuation<Int, Error>?
    var wasCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    /// Honours cancellation, as URLSession's async API does.
    func call() async throws -> Int {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { c in
                lock.lock(); continuation = c; let already = cancelled; lock.unlock()
                if already { resume(throwing: CancellationError()) }
            }
        } onCancel: {
            lock.lock(); cancelled = true; lock.unlock()
            resume(throwing: CancellationError())
        }
    }

    /// Ignores cancellation, as a call queued behind a busy actor does until
    /// the actor reaches it. Released by `release()`.
    func stubborn() async throws -> Int {
        try await withCheckedThrowingContinuation { c in
            lock.lock(); continuation = c; lock.unlock()
        }
    }

    func release() { resume(returning: 0) }

    private func resume(throwing error: Error) {
        lock.lock(); let c = continuation; continuation = nil; lock.unlock()
        c?.resume(throwing: error)
    }
    private func resume(returning value: Int) {
        lock.lock(); let c = continuation; continuation = nil; lock.unlock()
        c?.resume(returning: value)
    }
}

let bound: Duration = .milliseconds(300)
let slack = 0.1

print("== the bound")
do {
    let hung = Hung()
    let start = ContinuousClock.now
    var timedOut = false
    do { _ = try await LoopbackHealth.bounded(within: bound) { try await hung.call() } }
    catch is LoopbackStatusTimeout { timedOut = true }
    catch { print("  (threw \(error))") }
    let took = seconds(since: start)
    expect(timedOut, "a never-completing call ends in LoopbackStatusTimeout")
    expect(took < 0.3 + slack, "within the bound + 100 ms (took \(String(format: "%.3f", took)) s)")
    try? await Task.sleep(for: .milliseconds(50))
    expect(hung.wasCancelled, "and the abandoned call is cancelled, not left to run out its own timeout")
}
do {
    // A task group would wait for this one; the bound must not.
    // Released after 2 s whatever happens, so an implementation that waits
    // for it fails the timing below instead of hanging the suite.
    let hung = Hung()
    let release = Task { try? await Task.sleep(for: .seconds(2)); hung.release() }
    let start = ContinuousClock.now
    var timedOut = false
    do { _ = try await LoopbackHealth.bounded(within: bound) { try await hung.stubborn() } }
    catch is LoopbackStatusTimeout { timedOut = true }
    catch { print("  (threw \(error))") }
    let took = seconds(since: start)
    expect(timedOut && took < 0.3 + slack,
           "a call that ignores cancellation is still abandoned at the bound (took \(String(format: "%.3f", took)) s)")
    await release.value
}
do {
    let start = ContinuousClock.now
    let v = try? await LoopbackHealth.bounded(within: .seconds(5)) { 42 }
    expect(v == 42 && seconds(since: start) < 0.1, "an answer inside the bound is returned at once")
}
do {
    struct Refused: Error {}
    var got: Error?
    do { _ = try await LoopbackHealth.bounded(within: .seconds(5)) { () async throws -> Int in throw Refused() } }
    catch { got = error }
    expect(got is Refused, "the call's own error is passed through, not turned into a timeout")
}
do {
    let hung = Hung()
    let start = ContinuousClock.now
    let caller = Task { try await LoopbackHealth.bounded(within: .seconds(10)) { try await hung.call() } }
    try? await Task.sleep(for: .milliseconds(50))
    caller.cancel()
    let result = await caller.result
    var cancelled = false
    if case .failure(let e) = result, e is CancellationError { cancelled = true }
    expect(cancelled && seconds(since: start) < 0.5, "cancelling the caller ends it at once with CancellationError")
    try? await Task.sleep(for: .milliseconds(50))
    expect(hung.wasCancelled, "and cancels the call")
}

print("== two strikes")
do {
    var count = LoopbackStallCount()
    let first = count.abandoned()
    expect(first.strike == 1 && !first.recover, "one abandoned request does not replace the loopback")
    let second = count.abandoned()
    expect(second.strike == 2 && second.recover, "the second in a row does")
    let after = count.abandoned()
    expect(after.strike == 1 && !after.recover, "and the count starts over after it")
    count.answered()
    let reset = count.abandoned()
    expect(reset.strike == 1 && !reset.recover, "an answer in between resets the count")
    expect(LoopbackStallCount.strikes == 2, "two strikes (F16 §4.1)")
    expect(LoopbackHealth.statusBound == .seconds(3), "the bound is 3 s (F16 §4.1)")
}

print("== what is a loopback failure")
func urlError(_ code: Int, _ url: String) -> NSError {
    NSError(domain: NSURLErrorDomain, code: code,
            userInfo: [NSURLErrorFailingURLErrorKey: URL(string: url)!])
}
let bus = "http://127.0.0.1:52100/localapi/v0/watch-ipn-bus?mask=2"
let status = "http://127.0.0.1:52100/localapi/v0/status"
// The guard against F16 §1.2's tempting fix: the bus's long-poll dies with
// this every idle minute, by design.
expect(!LoopbackHealth.isLocalLoopbackConnectionFailure(urlError(NSURLErrorTimedOut, bus)),
       "a bus -1001 is not a loopback failure")
expect(!LoopbackHealth.isLocalLoopbackConnectionFailure(urlError(NSURLErrorTimedOut, status)),
       "nor is a status -1001")
expect(LoopbackHealth.isLocalLoopbackConnectionFailure(urlError(NSURLErrorCannotConnectToHost, status)),
       "a refused loopback (-1004) is")
expect(LoopbackHealth.isLocalLoopbackConnectionFailure(urlError(NSURLErrorNetworkConnectionLost, bus)),
       "a cut loopback (-1005) is")
expect(LoopbackHealth.isLocalLoopbackConnectionFailure(urlError(NSURLErrorCannotConnectToHost, "http://localhost:1/x"))
       && LoopbackHealth.isLocalLoopbackConnectionFailure(urlError(NSURLErrorCannotConnectToHost, "http://[::1]:1/x")),
       "on any loopback spelling")
expect(!LoopbackHealth.isLocalLoopbackConnectionFailure(urlError(NSURLErrorCannotConnectToHost, "https://gw.example.ts.net/")),
       "a refused remote host is not")
expect(!LoopbackHealth.isLocalLoopbackConnectionFailure(LoopbackStatusTimeout()),
       "an abandoned status request is its own signal, not a connection failure")

print(failures == 0 ? "\(checks)/\(checks) loopback stall checks passed" : "\(failures) of \(checks) loopback stall checks FAILED")
exit(failures == 0 ? 0 : 1)
