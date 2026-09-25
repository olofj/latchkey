// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

// Host-only tests for App/Tailnet Status/NodeStartFailure.swift (F8 §6.2).
//
// Pinned here: the sentence each cause gets — including from tsnet's message
// alone, because TsnetStart returns -1 for every Go error and a real failure
// carries no errno; the backoff schedule (1, 2, 4, 8, 16 s, then none); that
// only a successful start clears the failure; and that a logging refusal never
// counts down.
//
// Run:  make test-policy     (or: scripts/test-node-start-failure.sh)

import Foundation

var failures = 0
var checks = 0

func expectTrue(_ got: Bool, _ what: String) {
    checks += 1
    if !got {
        failures += 1
        print("  FAIL: \(what)")
    }
}

func expectEqual<T: Equatable>(_ got: T, _ want: T, _ what: String) {
    checks += 1
    if got != want {
        failures += 1
        print("  FAIL: \(what): got \(got), want \(want)")
    }
}

func node(_ errno: Int32?, _ message: String = "test hook", attempt: Int = 1) -> NodeStartFailure {
    NodeStartFailure(stage: .node, errnoValue: errno, message: message, attempt: attempt)
}

// MARK: - The errno → sentence mapping (F8 §2)

let permissions = "Its files can't be opened. This usually means the app's storage permissions changed."
expectEqual(node(EACCES).cause, permissions, "EACCES names storage permissions")
expectEqual(node(EPERM).cause, permissions, "EPERM names storage permissions")
expectEqual(node(ENOSPC).cause, "This device is out of storage. Free some space and it will start.",
            "ENOSPC names storage space")
expectEqual(node(EADDRINUSE).cause, "A previous run is still shutting down.",
            "EADDRINUSE names a previous run")
expectEqual(node(EIO, "disk said no").cause, "Tailscale reported: disk said no (EIO).",
            "anything else quotes tsnet with the errno's name")
expectEqual(node(nil, "something odd").cause, "Tailscale reported: something odd.",
            "no errno at all: tsnet's words, no empty parentheses")

// What a real failure looks like: `.internalError(message)`, errno from the text.
let real = node(nil, "open /x/Workspaces/1/state/tailscaled.state: permission denied")
expectEqual(real.errnoValue, EACCES, "a Go 'permission denied' is read as EACCES")
expectEqual(real.cause, permissions, "and gets the permissions sentence, not tsnet's raw words")
expectEqual(node(nil, "write /x: no space left on device").errnoValue, ENOSPC, "Go's ENOSPC text")
expectEqual(node(nil, "listen tcp 127.0.0.1:0: bind: address already in use").errnoValue, EADDRINUSE,
            "Go's EADDRINUSE text")
expectEqual(node(nil, "mkdir /x: operation not permitted").errnoValue, EPERM, "Go's EPERM text")
expectEqual(node(nil, "tailscaled.state: unexpected end of JSON input").errnoValue, nil,
            "a corrupt state file names no errno")
expectEqual(node(EIO, "permission denied").errnoValue, EIO, "an errno the error carries wins over the text")

expectEqual(NodeStartFailure.errno(named: "EACCES"), EACCES, "the hook takes names")
expectEqual(NodeStartFailure.errno(named: "enospc"), ENOSPC, "in any case")
expectEqual(NodeStartFailure.errno(named: "48"), 48, "and numbers")
expectEqual(NodeStartFailure.errno(named: "EBOGUS"), nil, "and refuses the rest")

// MARK: - The backoff schedule (F8 §4.3)

let schedule = (1...7).map { NodeStartFailure.retryDelay(afterFailure: $0) }
expectEqual(schedule, [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16), nil, nil],
            "five retries at 1, 2, 4, 8, 16 s, then no more")
expectEqual(NodeStartFailure.retryDelay(afterFailure: 0), nil, "no failure, no retry")
expectEqual(node(EACCES, attempt: 5).nextRetryIn, .seconds(16), "the fifth failure waits 16 s")
expectEqual(node(EACCES, attempt: 6).nextRetryIn, nil, "the sixth stops the countdown")

// MARK: - The logging refusal (F8 §4.6)

let logging = NodeStartFailure(stage: .logging, errnoValue: EACCES, message: "EACCES", attempt: 1)
expectEqual(logging.nextRetryIn, nil, "a logging refusal has no countdown")
expectEqual(logging.cause,
            "Latchkey can't open its own log files, so it won't start a node until that is fixed.",
            "and its own sentence, whatever the errno")

// MARK: - Cleared only by success (F8 §4.2)

var tracker = NodeStartTracker()
expectEqual(tracker.failure, nil, "no failure before a start")
let first = tracker.failed(stage: .node, errnoValue: EADDRINUSE, message: "busy")
expectEqual(first.attempt, 1, "the first failure is attempt 1")
expectEqual(first.nextRetryIn, .seconds(1), "and retries in 1 s")
let second = tracker.failed(stage: .node, errnoValue: EADDRINUSE, message: "busy")
expectEqual(second.attempt, 2, "failures count up")
expectEqual(second.nextRetryIn, .seconds(2), "and back off")
tracker.restartSchedule()
expectTrue(tracker.failure != nil, "a fresh schedule (Try now, foreground) does not clear the failure")
expectEqual(tracker.failed(stage: .node, errnoValue: EADDRINUSE, message: "busy").attempt, 1,
            "but restarts the count")
for _ in 0..<10 { _ = tracker.failed(stage: .node, errnoValue: EIO, message: "no") }
expectEqual(tracker.failure?.nextRetryIn, nil, "a spent schedule stays spent")
expectTrue(tracker.failure != nil, "and still shows the failure")
tracker.succeeded()
expectEqual(tracker.failure, nil, "a successful start clears it")
expectEqual(tracker.failed(stage: .node, errnoValue: EIO, message: "no").attempt, 1,
            "and a later failure starts a new schedule")

if failures == 0 {
    print("\n\(checks)/\(checks) node start failure checks passed")
} else {
    print("\n\(failures) of \(checks) node start failure checks FAILED")
    exit(1)
}
