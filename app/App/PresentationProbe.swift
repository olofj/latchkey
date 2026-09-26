// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

//
//  PresentationProbe.swift
//  Latchkey
//
//  The UI tests' instrument for "nothing is sliding" (Testing builds only).
//
//  A sheet is in the accessibility tree from the first frame of its
//  presentation, and UIKit drops touches until the transition completes. So
//  a test that waits for a sheet's button to exist and then taps it can tap
//  during the slide and reach nothing: XCUITest reports no error, and the
//  failure shows up steps later as a screen that never opened (F5's switcher
//  test closed the token sheet that way). The same holds for a dismissal,
//  where the sheet can still cover what the test taps next.
//
//  `ui-presentation` reads, live when a test asks, `moving` while any view
//  controller in the window's presentation chain is being presented or
//  dismissed, and `settled` otherwise. Seeing a sheet's element and then
//  `settled` means the sheet is up and takes touches; UITestSupport's
//  `tapWhenSettled` waits for both.
//

#if LATCHKEY_TEST_HOOKS && canImport(UIKit)
import SwiftUI
import UIKit

struct PresentationProbe: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView { ProbeView() }
    func updateUIView(_ view: UIView, context: Context) {}

    private final class ProbeView: UIView {
        init() {
            super.init(frame: .zero)
            isAccessibilityElement = true
            accessibilityIdentifier = "ui-presentation"
            isUserInteractionEnabled = false
        }
        required init?(coder: NSCoder) { fatalError("not used") }

        override var accessibilityValue: String? {
            get {
                guard let window else { return "no-window" }
                return Self.moving(from: window.rootViewController) ? "moving" : "settled"
            }
            set {}
        }

        /// The root, its children (a navigation push is a child's
        /// transition) and everything presented over it. A transition in
        /// progress has a coordinator until it completes; the flags cover the
        /// moment before one is attached.
        private static func moving(from vc: UIViewController?) -> Bool {
            guard let vc else { return false }
            if vc.transitionCoordinator != nil || vc.isBeingPresented || vc.isBeingDismissed {
                return true
            }
            return vc.children.contains { moving(from: $0) } || moving(from: vc.presentedViewController)
        }
    }
}
#endif
