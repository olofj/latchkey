// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

//
//  AppDiagnostics.swift
//  Latchkey
//
//  Process-lifetime counters for failures a user would otherwise experience
//  as "the app is flaky" with nothing to point at. Shown in Settings →
//  Diagnostics, the only diagnostic surface on a phone that cannot be attached
//  to a Mac. M8.2's diagnostics screen builds on this.
//
//  In memory only: they describe this run of the app, and a relaunch is the
//  natural reset.
//

import Foundation
import Combine

@MainActor
final class AppDiagnostics: ObservableObject {
    static let shared = AppDiagnostics()

    /// Times WebKit's web content process died under the dashboard (R7).
    /// Counted separately from network errors on purpose: upstream showed
    /// both as the same error page, which made a routine memory kill look
    /// like a tailnet outage.
    @Published var webContentTerminations = 0
    /// Of those, how many were reloaded automatically.
    @Published var webContentAutoReloads = 0
    /// Of those, how many hit the reload budget and fell back to the error
    /// page, so the user had to reload by hand.
    @Published var webContentGaveUp = 0

    private init() {}
}
