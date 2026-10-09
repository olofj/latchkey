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
//  Scroll views are the exception: an edge swipe owns its touch, so the
//  chat behind the drawer does not scroll with the finger's drift (F24
//  §7). Their pans wait for ours to fail, which a touch away from the
//  edge does at once.
//
//  It opens the drawer only once the finger has travelled `travel` points
//  inward, more across than up or down, or on a quick flick: firing at
//  `.began`, a few points in, threw the drawer out before the swipe
//  looked deliberate.
//

#if canImport(UIKit)
import UIKit
import WebKit

final class EdgeSwipe: NSObject, UIGestureRecognizerDelegate {
    enum Side: String { case left, right }

    /// The app's own world for `edgeSwipeOpenPane`: the page cannot see or
    /// call it.
    static let world = WKContentWorld.world(name: "latchkey-edge-swipe")

    /// Inward travel, in points, before a swipe opens its drawer.
    static let travel: CGFloat = 40
    /// A swipe released short of `travel` still opens on a flick: at
    /// least half the travel at this inward speed, in points a second.
    static let flick: CGFloat = 500

    private let onSwipe: (Side) -> Void
    /// The recognisers whose current gesture has already opened a drawer.
    private var fired: Set<ObjectIdentifier> = []

    /// `onSwipe` runs at most once per gesture.
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
        let id = ObjectIdentifier(recogniser)
        switch recogniser.state {
        case .began:
            fired.remove(id)
        case .changed, .ended:
            guard !fired.contains(id), let view = recogniser.view else { return }
            let side: Side = recogniser.edges.contains(.left) ? .left : .right
            let sign: CGFloat = side == .left ? 1 : -1
            let t = recogniser.translation(in: view)
            let inward = t.x * sign, across = inward > abs(t.y)
            let flick = recogniser.velocity(in: view).x * sign
            if across && (inward >= Self.travel
                          || (recogniser.state == .ended && inward >= Self.travel / 2 && flick >= Self.flick)) {
                fired.insert(id)
                onSwipe(side)
            }
        default:
            break
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        !(other.view is UIScrollView)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        other.view is UIScrollView
    }
}
#endif
