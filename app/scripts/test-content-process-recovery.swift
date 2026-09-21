// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

// Host-only tests for App/Browser/ContentProcessRecovery.swift (revision R7).
//
// Run:  make test-policy     (or: scripts/test-content-process-recovery.sh)

import Foundation

var failures = 0
var checks = 0

func expect(_ cond: Bool, _ what: String) {
    checks += 1
    if !cond { failures += 1; print("  FAIL: \(what)") }
}

func section(_ name: String) { print("\n== \(name)") }

let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

section("two reloads per sixty seconds, then give up")
var r = ContentProcessRecovery()
expect(r.shouldReload(now: t0), "first termination reloads")
expect(r.shouldReload(now: t0.addingTimeInterval(5)), "second termination within the window reloads")
expect(!r.shouldReload(now: t0.addingTimeInterval(10)), "third within the window gives up (error page)")
expect(!r.shouldReload(now: t0.addingTimeInterval(59)), "still giving up just inside the window")

section("the budget refills as reloads age out")
expect(r.shouldReload(now: t0.addingTimeInterval(60)), "the first reload has aged out at exactly 60 s")
expect(!r.shouldReload(now: t0.addingTimeInterval(61)), "only one slot freed; the 5 s one is still inside")
expect(r.shouldReload(now: t0.addingTimeInterval(65)), "the 5 s reload has aged out too")

section("a refusal does not consume budget")
var q = ContentProcessRecovery()
_ = q.shouldReload(now: t0)
_ = q.shouldReload(now: t0.addingTimeInterval(1))
for i in 2..<20 { _ = q.shouldReload(now: t0.addingTimeInterval(Double(i))) }
expect(q.recentReloads.count == 2, "refused attempts are not recorded as reloads")
expect(q.shouldReload(now: t0.addingTimeInterval(61)), "so the budget refills on schedule, not later")

section("rare terminations always reload")
var rare = ContentProcessRecovery()
var allReloaded = true
for hour in 0..<24 {
    allReloaded = allReloaded && rare.shouldReload(now: t0.addingTimeInterval(Double(hour) * 3600))
}
expect(allReloaded, "one termination an hour, all day: every one reloads")

section("configurable")
var strict = ContentProcessRecovery(maxReloads: 1, window: 10)
expect(strict.shouldReload(now: t0), "one allowed")
expect(!strict.shouldReload(now: t0.addingTimeInterval(9)), "second inside 10 s refused")
expect(strict.shouldReload(now: t0.addingTimeInterval(10)), "allowed again at 10 s")

print("")
if failures == 0 {
    print("\(checks)/\(checks) content process recovery checks passed")
} else {
    print("\(failures) of \(checks) content process recovery checks FAILED")
    exit(1)
}
