// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

//
//  AppBarRetraction.swift
//  Latchkey
//
//  When the app bar is on screen and when it is not (F15 §4a).
//
//  The bar is ABSENT in the steady state: the page fills the screen as it did
//  before F15. A deliberate scroll up (the finger moving down) brings it in;
//  a deliberate scroll down takes it away again. Safari's model, with the
//  default inverted, because a permanent 44 pt band for one gear was a bad
//  trade (Olof, 2026-09-24).
//
//  The bar DISPLACES the page rather than overlaying it: the web view's top
//  edge is the bar's bottom edge, because no gateway can be trusted to inset
//  itself (F9 §0). So every change of state resizes the web view and reflows
//  the page. The policy exists to make that rare and deliberate:
//
//  - Only finger travel counts. The input is the finger's movement while it
//    is on the glass, reported by `PageScriptSources.appBarObserver`; momentum
//    produces no touches, so nothing changes mid-momentum, and a page that
//    scrolls itself (a chat following new messages) changes nothing either.
//  - One drag, one direction, `threshold` points. Travel restarts at each
//    touch and whenever the finger reverses, so reading nudges never add up.
//  - Hiding needs something that really scrolled, with more range than the
//    bar is tall. Showing needs only the finger, on any page.
//  - A page that cannot scroll has the bar, whatever the finger did: on it no
//    scroll up exists to bring the bar in, so hidden would mean gone (F15
//    §4b). The page script reports its largest scroll range (`extent`) as the
//    page changes, and until a new document has reported one it counts as not
//    scrolling. The hysteresis is the bar's height: shown, the page must have
//    more range than the bar to lose it; hidden, it keeps the page until the
//    page has no range left, so the room the bar gives back can never make it
//    come straight back.
//
//  Pure Foundation, so `scripts/test-app-bar-retraction.sh` compiles it alone.
//

import Foundation

struct AppBarRetraction: Sendable, Equatable {
    /// The bar's height in points. The web view starts this far below the
    /// window's safe-area top while the bar is shown (L1 pins it).
    nonisolated static let barHeight: Double = 44

    /// Finger travel, in points, of one drag in one direction before the bar
    /// changes state. See F15 §9 for why 64: above the 10–40 pt corrections
    /// made while reading, below the travel of an ordinary scrolling drag.
    nonisolated static let threshold: Double = 64

    /// One observation from the page script, in screen points.
    enum Sample: Sendable, Equatable {
        /// One finger touched down. A second finger ends the drag.
        case began
        /// The finger moved by (dx, dy) since the last sample; dy < 0 is up.
        /// `scrollRange` is the largest vertical scroll range of anything that
        /// scrolled during this touch, 0 if nothing did.
        case moved(dx: Double, dy: Double, scrollRange: Double)
        case ended
        /// The page's largest vertical scroll range, measured as the page
        /// loads and changes, touch or no touch. See `extent(_:)`.
        case extent(Double)
    }

    /// Whether the bar is off screen: the owner's choice, and the default,
    /// unless something requires it.
    var retracted: Bool { away && scrolls && mayRetract }

    /// False whenever something requires the bar on screen (assistive
    /// technology, a state page, a pinned control). Travel is then discarded,
    /// and the owner's choice is left as it was for when the reason clears.
    var mayRetract = true {
        didSet { if !mayRetract { run = 0 } }
    }

    /// While true, `extent` reports are held and the last one applies when it
    /// turns false. Set while the software keyboard is up: it shrinks the
    /// viewport and so changes what scrolls, and the bar must not move under
    /// a field being typed into. The finger still works.
    var extentHeld = false {
        didSet { if !extentHeld, let r = heldExtent { heldExtent = nil; extent(r) } }
    }

    /// The owner's choice: true (the steady state) until a scroll up asks for
    /// the bar.
    private var away = true
    /// Whether the page scrolls enough to do without the bar.
    private var scrolls = false
    private var heldExtent: Double?
    /// Signed travel of the current drag since it last changed direction:
    /// positive is the finger moving up, toward hiding.
    private var run: Double = 0
    private var touching = false

    /// Feeds one sample. Returns whether `retracted` changed.
    @discardableResult
    mutating func observe(_ sample: Sample) -> Bool {
        if case .extent(let range) = sample { return extent(range) }
        let before = retracted
        switch sample {
        case .extent:
            break
        case .began:
            touching = true
            run = 0
        case .ended:
            touching = false
            run = 0
        case .moved(let dx, let dy, let scrollRange):
            // A move with no touch-down seen (a lost message, a document that
            // started mid-touch) proves nothing. Horizontal moves are a
            // carousel or a text selection, not a scroll.
            guard touching, mayRetract, abs(dy) > abs(dx) else { break }
            let travel = -dy
            if run != 0, (travel > 0) != (run > 0) { run = 0 }
            run += travel
            if run >= Self.threshold, scrollRange > Self.barHeight {
                // Something scrolled with more range than the bar: proof the
                // page scrolls, whatever the last report said.
                scrolls = true
                away = true
                run = 0
            } else if run <= -Self.threshold {
                away = false
                run = 0
            }
        }
        return retracted != before
    }

    /// The page's largest vertical scroll range, in points, as the page script
    /// measures it. Returns whether `retracted` changed.
    @discardableResult
    mutating func extent(_ range: Double) -> Bool {
        if extentHeld { heldExtent = range; return false }
        let before = retracted
        scrolls = before ? range >= 1 : range > Self.barHeight
        return retracted != before
    }

    /// A new document: the steady state, no travel carried over, and shown
    /// until the page reports that it scrolls.
    mutating func documentChanged() {
        away = true
        scrolls = false
        heldExtent = nil
        run = 0
    }
}
