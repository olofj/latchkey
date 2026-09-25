// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

//
//  AppBarController.swift
//  Latchkey
//
//  Holds the app bar's shown/retracted state for one web view (F15). The
//  policy is `AppBarRetraction`; this adds the reasons the bar must stay on
//  screen whatever the finger does:
//
//  - VoiceOver or Switch Control is running. A retracted bar is off screen,
//    and an element that is off screen is not one those users can reach
//    reliably, so for them it never retracts, and turning either on brings a
//    retracted bar straight back (F15 §4b: hidden must not mean gone).
//  - A state page (connecting, failed) covers the web view.
//  - A control that must not be scrolled away is in the bar (the sign-in
//    button, the only one there is).
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
    @Published private(set) var retracted = false

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
        policy.observe(sample, mayRetract: mayRetract)
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

    /// A new document starts with the bar shown (F15 §5).
    func documentChanged() {
        policy.reset()
        publish()
    }

    private func reconsider() {
        if !mayRetract { policy.reset() }
        publish()
    }

    private func publish() {
        if retracted != policy.retracted { retracted = policy.retracted }
    }
}
