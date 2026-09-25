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
let bar = AppBarRetraction.barHeight
let tall = 2000.0   // a scroll range far larger than the bar

/// One drag: touch down, `steps` equal vertical moves totalling `dy`, lift.
/// dy < 0 is the finger moving up: scrolling the page down.
@discardableResult
func drag(_ p: inout AppBarRetraction, dy: Double, steps: Int = 8, range: Double = tall,
          lift: Bool = true) -> Bool {
    p.observe(.began)
    for _ in 0..<steps {
        p.observe(.moved(dx: 0, dy: dy / Double(steps), scrollRange: range))
    }
    if lift { p.observe(.ended) }
    return p.retracted
}

/// A policy on a page that has reported it scrolls.
func scrolling() -> AppBarRetraction {
    var p = AppBarRetraction()
    p.observe(.extent(tall))
    return p
}

section("the steady state is no bar")
var p = AppBarRetraction()
expect(!p.retracted, "a document that has not reported its extent has the bar: it may not scroll (F15 §4b)")
expect(p.observe(.extent(tall)) && p.retracted, "a page that scrolls: the bar goes, untouched (F15 §5)")

section("a deliberate scroll up brings it in, and one down takes it away")
p = scrolling()
expect(!drag(&p, dy: t + 1), "a drag down (scrolling up) of more than the threshold shows it")
expect(!drag(&p, dy: 300), "further drags down keep it")
expect(drag(&p, dy: -(t + 1)), "a drag up of more than the threshold hides it again")
expect(drag(&p, dy: -300), "further drags up keep it hidden")

section("small movements never change it")
p = scrolling()
expect(drag(&p, dy: t - 1), "just under the threshold: still hidden")
expect(drag(&p, dy: t - 1), "and a second such drag does not add up: travel restarts per touch")
expect(drag(&p, dy: 30) && drag(&p, dy: 30) && drag(&p, dy: 30), "reading nudges never add up")
drag(&p, dy: 200)
expect(!p.retracted, "(setup) shown")
expect(!drag(&p, dy: -(t - 1)), "shown, a small drag up does not hide it")

section("a reversal restarts the count")
p = scrolling()
p.observe(.began)
p.observe(.moved(dx: 0, dy: t - 10, scrollRange: tall))
p.observe(.moved(dx: 0, dy: -20, scrollRange: tall))
p.observe(.moved(dx: 0, dy: t - 10, scrollRange: tall))
expect(p.retracted, "down, a little up, down again: neither leg reached the threshold")
p.observe(.moved(dx: 0, dy: 20, scrollRange: tall))
expect(!p.retracted, "the leg since the reversal reaches it")

section("never mid-momentum: only finger travel counts")
p = scrolling()
drag(&p, dy: 20)
expect(p.retracted, "a flick with 20 pt of finger travel does not show it, however far it coasts")
p.observe(.moved(dx: 0, dy: 500, scrollRange: tall))
expect(p.retracted, "a move with no touch down (coasting, a lost message) changes nothing")

section("a page that cannot scroll keeps the bar (F15 §4b)")
p = AppBarRetraction()
expect(!p.observe(.extent(0)) && !p.retracted, "extent 0: shown")
expect(!p.observe(.extent(bar)) && !p.retracted,
       "extent no more than the bar: it would stop scrolling once the bar went, so it stays")
expect(!drag(&p, dy: -400, range: 0), "nothing scrolled: no drag hides it")
expect(!drag(&p, dy: -400, range: bar), "nor one that scrolled less than the bar")
expect(p.observe(.extent(bar + 1)) && p.retracted, "one point more and it goes")
expect(!p.observe(.extent(bar - 1)) && p.retracted,
       "hidden, the room the bar gave back does not bring it straight back (hysteresis)")
expect(p.observe(.extent(0)) && !p.retracted, "but a page with no range left gets it back at once")

section("a drag that scrolls proves the page scrolls")
p = AppBarRetraction()
expect(drag(&p, dy: -(t + 1), range: bar + 1), "no report yet, but a drag up scrolled something: hidden")
p = AppBarRetraction()
expect(drag(&p, dy: 200) == false && !drag(&p, dy: -200, range: 0),
       "a page that never reported, whose drags scroll nothing: the bar stays")

section("showing never needs a scroll: always reachable")
p = scrolling()
expect(!drag(&p, dy: t + 1, range: 0), "a drag down that scrolls nothing still shows it")

section("horizontal and multi-touch are not scrolls")
p = scrolling()
p.observe(.began)
for _ in 0..<10 { p.observe(.moved(dx: 40, dy: 20, scrollRange: tall)) }
expect(p.retracted, "a mostly horizontal drag (a carousel) does not show it")
p.observe(.ended)

section("mayRetract false: shown at once, and stays")
p = scrolling()
expect(p.retracted, "(setup) hidden")
p.mayRetract = false
expect(!p.retracted, "VoiceOver on (or a state page): shown at once")
expect(!drag(&p, dy: -400), "and no drag hides it while that holds")
expect(!p.observe(.extent(tall)), "nor does the page's extent")
drag(&p, dy: 400)
p.mayRetract = true
expect(p.retracted, "a drag made while it held was discarded: the steady state resumes when it clears")
p.observe(.began)
p.observe(.moved(dx: 0, dy: t - 1, scrollRange: tall))
p.mayRetract = false
p.mayRetract = true
p.observe(.moved(dx: 0, dy: 2, scrollRange: tall))
expect(p.retracted, "and the travel of a drag in progress is discarded too")

section("the keyboard holds the extent, not the finger")
p = AppBarRetraction()
p.observe(.extent(0))
p.extentHeld = true
expect(!p.observe(.extent(tall)) && !p.retracted,
       "keyboard up, the shrunken viewport now scrolls: the bar stays put")
p.extentHeld = false
expect(p.retracted, "keyboard down: the last extent applies")
p = scrolling()
p.extentHeld = true
expect(!p.observe(.extent(0)) && p.retracted, "keyboard up: a page that stops scrolling does not bring it in")
expect(!drag(&p, dy: t + 1), "but the finger still shows it")
expect(drag(&p, dy: -(t + 1)), "and hides it")
p.observe(.extent(tall))
p.extentHeld = false
expect(p.retracted, "keyboard down: the latest held extent is the one that applies")

section("a new document")
p = scrolling()
drag(&p, dy: 200)
expect(!p.retracted, "(setup) shown by the owner")
p.documentChanged()
expect(!p.retracted, "shown until the new page reports its extent")
p.observe(.extent(tall))
expect(p.retracted, "then the steady state, not the old page's choice")
p.extentHeld = true
p.observe(.extent(0))
p.documentChanged()
p.extentHeld = false
expect(!p.retracted, "an extent held for the old page is not applied to the new one")
p = scrolling()
p.observe(.began)
p.observe(.moved(dx: 0, dy: t - 1, scrollRange: tall))
p.documentChanged()
p.observe(.extent(tall))
p.observe(.moved(dx: 0, dy: 2, scrollRange: tall))
expect(p.retracted, "and the travel of a drag in progress is discarded")

print("")
if failures == 0 {
    print("\(checks)/\(checks) app bar retraction checks passed")
} else {
    print("\(failures) of \(checks) app bar retraction checks FAILED")
    exit(1)
}
