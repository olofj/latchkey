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
    /// Times the SOCKS relay's listener was restarted because a page load
    /// could not reach it, a probe found it dead, or it reported failure
    /// (R30).
    @Published var socksRelayRestarts = 0
    /// Self-probes of the relay's listener (R30 review): a loopback connect
    /// on the foreground, after an unanswered session check, and as the last
    /// guard before a page-driven restart. And how many found it dead.
    @Published var socksRelayProbes = 0
    @Published var socksRelayProbesFailed = 0
    /// Times WebKit was pointed at tsnet's proxy directly because no relay
    /// listener could be started (R30 review): from then on the log has no
    /// per-connection lines, which this row explains.
    @Published var socksRelayFallbacks = 0

    private init() {}
}
