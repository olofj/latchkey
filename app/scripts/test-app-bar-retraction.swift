// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

// Host-only tests for App/Browser/AppBarRetraction.swift (F15 §4a, §4b).
//
// Run:  make test-policy     (or: scripts/test-app-bar-retraction.sh)

import Foundation

var failures = 0
var checks = 0

func expect(_ cond: Bool, _ what: String) {
    checks += 1
    if !cond { failures += 1; print("  FAIL: \(what)") }
}

func section(_ name: String) { print("\n== \(name)") }

let t = AppBarRetraction.threshold
let tall = 2000.0   // a scroll range far larger than the bar

/// One drag: touch down, `steps` equal vertical moves totalling `dy`, lift.
@discardableResult
func drag(_ p: inout AppBarRetraction, dy: Double, steps: Int = 8, range: Double = tall,
          mayRetract: Bool = true, lift: Bool = true) -> Bool {
    p.observe(.began, mayRetract: mayRetract)
    for _ in 0..<steps {
        p.observe(.moved(dx: 0, dy: dy / Double(steps), scrollRange: range), mayRetract: mayRetract)
    }
    if lift { p.observe(.ended, mayRetract: mayRetract) }
    return p.retracted
}

section("a deliberate drag retracts, and one back returns it")
var p = AppBarRetraction()
expect(!p.retracted, "starts shown (F15 §5)")
expect(drag(&p, dy: -(t + 1)), "a drag up of more than the threshold retracts")
expect(drag(&p, dy: -300), "further drags up keep it retracted")
expect(!drag(&p, dy: t + 1), "a drag down of more than the threshold brings it back")

section("small movements never change it")
p = AppBarRetraction()
expect(!drag(&p, dy: -(t - 1)), "just under the threshold: still shown")
expect(!drag(&p, dy: -(t - 1)), "and a second such drag does not add up: travel restarts per touch")
expect(!drag(&p, dy: -30) && !drag(&p, dy: -30) && !drag(&p, dy: -30), "reading nudges never add up")
drag(&p, dy: -200)
expect(p.retracted, "(setup) retracted")
expect(drag(&p, dy: t - 1), "retracted, a small drag down does not return it")

section("a reversal restarts the count")
p = AppBarRetraction()
p.observe(.began, mayRetract: true)
p.observe(.moved(dx: 0, dy: -(t - 10), scrollRange: tall), mayRetract: true)
p.observe(.moved(dx: 0, dy: 20, scrollRange: tall), mayRetract: true)
p.observe(.moved(dx: 0, dy: -(t - 10), scrollRange: tall), mayRetract: true)
expect(!p.retracted, "up, a little down, up again: neither leg reached the threshold")
p.observe(.moved(dx: 0, dy: -20, scrollRange: tall), mayRetract: true)
expect(p.retracted, "the leg since the reversal reaches it")

section("never mid-momentum: only finger travel counts")
p = AppBarRetraction()
drag(&p, dy: -20)
expect(!p.retracted, "a flick with 20 pt of finger travel does not retract, however far it coasts")
p.observe(.moved(dx: 0, dy: -500, scrollRange: tall), mayRetract: true)
expect(!p.retracted, "a move with no touch down (coasting, a lost message) changes nothing")

section("a page too short to scroll keeps the bar (F15 §4b)")
p = AppBarRetraction()
expect(!drag(&p, dy: -400, range: 0), "nothing scrolled: never retracts")
expect(!drag(&p, dy: -400, range: AppBarRetraction.barHeight),
       "scroll range no more than the bar: it would stop scrolling once retracted, so it never does")
expect(drag(&p, dy: -400, range: AppBarRetraction.barHeight + 1), "one point more and it may")

section("returning never needs a scroll: always reachable")
p = AppBarRetraction()
drag(&p, dy: -200)
expect(!drag(&p, dy: t + 1, range: 0), "a drag down on a page that cannot scroll brings it back")

section("horizontal and multi-touch are not scrolls")
p = AppBarRetraction()
p.observe(.began, mayRetract: true)
for _ in 0..<10 { p.observe(.moved(dx: -40, dy: -20, scrollRange: tall), mayRetract: true) }
expect(!p.retracted, "a mostly horizontal drag (a carousel) does not retract")
p.observe(.ended, mayRetract: true)

section("mayRetract false: shown at once, and stays")
p = AppBarRetraction()
drag(&p, dy: -200)
expect(p.retracted, "(setup) retracted")
expect(p.observe(.moved(dx: 0, dy: -10, scrollRange: tall), mayRetract: false) && !p.retracted,
       "VoiceOver on (or a state page): shown on the next sample, and it says it changed")
expect(!drag(&p, dy: -400, mayRetract: false), "and no drag retracts it while that holds")

section("reset")
p = AppBarRetraction()
drag(&p, dy: -200)
p.reset()
expect(!p.retracted, "reset shows it")
p.observe(.began, mayRetract: true)
p.observe(.moved(dx: 0, dy: -(t - 1), scrollRange: tall), mayRetract: true)
p.reset()
p.observe(.moved(dx: 0, dy: -2, scrollRange: tall), mayRetract: true)
expect(!p.retracted, "and discards the travel of a drag in progress")

print("")
if failures == 0 {
    print("\(checks)/\(checks) app bar retraction checks passed")
} else {
    print("\(failures) of \(checks) app bar retraction checks FAILED")
    exit(1)
}
