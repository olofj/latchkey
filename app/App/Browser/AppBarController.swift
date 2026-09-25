// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

//
//  AppBarController.swift
//  Latchkey
//
//  Holds the app bar's shown/retracted state for one web view (F15). The
//  policy is `AppBarRetraction`, whose steady state is retracted; this adds
//  the reasons the bar must be on screen whatever the finger does:
//
//  - VoiceOver or Switch Control is running. A retracted bar is off screen,
//    and an element that is off screen is not one those users can reach
//    reliably, so for them it never retracts, and turning either on brings a
//    retracted bar straight back (F15 §4b: hidden must not mean gone).
//  - A state page (connecting, failed) covers the web view.
//  - A control that must not be scrolled away is in the bar (the sign-in
//    button, the only one there is).
//
//  And one reason the bar must NOT move: the software keyboard. It resizes
//  the web view (F13), which can make a page start or stop scrolling; while
//  it is up the page's extent reports are held, so the bar stays as it was
//  when typing began and moves only for the finger.
//
//  Owned by `BrowserViewModel`, which feeds it the page script's samples and
//  its page state; `AppBar` reads it.
//

import Combine
import Foundation
#if canImport(UIKit)
import UIKit
#endif

final class AppBarController: ObservableObject {
    @Published private(set) var retracted = AppBarRetraction().retracted

    private var policy = AppBarRetraction()
    private var pageCovered = false
    private var pinned = false
    private var observers: [AnyCancellable] = []

    init() {
#if canImport(UIKit)
        for name in [UIAccessibility.voiceOverStatusDidChangeNotification,
                     UIAccessibility.switchControlStatusDidChangeNotification] {
            NotificationCenter.default.publisher(for: name)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.reconsider() }
                .store(in: &observers)
        }
        NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.policy.extentHeld = true }
            .store(in: &observers)
        NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.policy.extentHeld = false
                self?.publish()
            }
            .store(in: &observers)
#endif
    }

    /// VoiceOver or Switch Control, read live. `-UITestAssumeVoiceOver` stands
    /// in for them in L1, which cannot turn VoiceOver on.
    static var assistiveTechnologyRunning: Bool {
#if canImport(UIKit)
        if UIAccessibility.isVoiceOverRunning || UIAccessibility.isSwitchControlRunning { return true }
#endif
        return TestHooks.flag("-UITestAssumeVoiceOver")
    }

    var mayRetract: Bool { !pageCovered && !pinned && !Self.assistiveTechnologyRunning }

    func observe(_ sample: AppBarRetraction.Sample) {
        policy.mayRetract = mayRetract
        policy.observe(sample)
        publish()
    }

    func setPageCovered(_ covered: Bool) {
        pageCovered = covered
        reconsider()
    }

    func setPinned(_ value: Bool) {
        pinned = value
        reconsider()
    }

    /// A new document starts in the steady state, retracted, once it has
    /// shown that it scrolls (F15 §5).
    func documentChanged() {
        policy.documentChanged()
        publish()
    }

    private func reconsider() {
        policy.mayRetract = mayRetract
        publish()
    }

    private func publish() {
        if retracted != policy.retracted { retracted = policy.retracted }
    }
}
