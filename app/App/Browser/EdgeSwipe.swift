// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

//
//  EdgeSwipe.swift
//  Latchkey
//
//  F24: a swipe in from the screen's left edge opens the dashboard's
//  sessions drawer, from the right edge its activity drawer. The page's
//  own drawer swipe leaves the outer 24 px alone (it expects Safari's back
//  gesture there), and this web view has no back gesture, so the strip
//  was dead. Two screen-edge recognisers take it; the page script
//  `PageScriptSources.edgeSwipeOpenPane` does the opening.
//
//  A screen-edge recogniser only begins on a touch that starts at the
//  edge, so a horizontal scroll inside the page never reaches it. It is
//  allowed to recognise alongside WebKit's own recognisers, which would
//  otherwise hold it back; once it begins, the page's touch is cancelled.
//

#if canImport(UIKit)
import UIKit
import WebKit

final class EdgeSwipe: NSObject, UIGestureRecognizerDelegate {
    enum Side: String { case left, right }

    /// The app's own world for `edgeSwipeOpenPane`: the page cannot see or
    /// call it.
    static let world = WKContentWorld.world(name: "latchkey-edge-swipe")

    private let onSwipe: (Side) -> Void

    /// `onSwipe` runs once per gesture, when it begins.
    init(onSwipe: @escaping (Side) -> Void) {
        self.onSwipe = onSwipe
    }

    /// Adds the two recognisers to `view`. A recogniser does not retain
    /// its target, so the caller keeps this object as long as the view.
    func install(on view: UIView) {
        for edge in [UIRectEdge.left, .right] {
            let recogniser = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(pan(_:)))
            recogniser.edges = edge
            recogniser.delegate = self
            recogniser.name = "latchkey-edge-swipe-\(edge == .left ? "left" : "right")"
            view.addGestureRecognizer(recogniser)
        }
    }

    @objc private func pan(_ recogniser: UIScreenEdgePanGestureRecognizer) {
        guard recogniser.state == .began else { return }
        onSwipe(recogniser.edges.contains(.left) ? .left : .right)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}
#endif
