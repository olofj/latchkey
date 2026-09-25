// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

//
//  AppBarRetraction.swift
//  Latchkey
//
//  When the app bar retracts and when it comes back (F15 §4a).
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
//  - Retracting needs something that really scrolled, with more range than the
//    bar is tall: a page too short to scroll keeps the bar (F15 §4b), and so
//    does one that would stop scrolling the moment the bar gave it room.
//  - Returning needs only the finger. A downward drag of `threshold` brings
//    the bar back on any page, scrollable or not, so a retracted bar can
//    always be recovered by a gesture every page can perform.
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
    }

    private(set) var retracted = false
    /// Signed travel of the current drag since it last changed direction:
    /// positive is the finger moving up, toward retracting.
    private var run: Double = 0
    private var touching = false

    /// Feeds one sample. `mayRetract` is false whenever something requires the
    /// bar on screen (assistive technology, a state page, a pinned control);
    /// the bar is then shown at once and travel is discarded. Returns whether
    /// `retracted` changed.
    @discardableResult
    mutating func observe(_ sample: Sample, mayRetract: Bool) -> Bool {
        let before = retracted
        switch sample {
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
            guard touching, abs(dy) > abs(dx) else { break }
            let travel = -dy
            if run != 0, (travel > 0) != (run > 0) { run = 0 }
            run += travel
            if !retracted, run >= Self.threshold, scrollRange > Self.barHeight, mayRetract {
                retracted = true
                run = 0
            } else if retracted, run <= -Self.threshold {
                retracted = false
                run = 0
            }
        }
        if !mayRetract { retracted = false }
        return retracted != before
    }

    /// Back to shown, with no travel carried over: a new document, or a
    /// reason to be on screen.
    mutating func reset() {
        retracted = false
        run = 0
    }
}
