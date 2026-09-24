// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

//
//  ContentProcessRecovery.swift
//  Latchkey
//
//  When to reload after WebKit's web content process dies (revision R7,
//  finding H10).
//
//  iOS kills a backgrounded app's web content process routinely under memory
//  pressure, and a foreground one occasionally. Upstream turned every
//  termination into a "cannot load from network" error page and never
//  reloaded — so a routine memory kill looked exactly like a tailnet outage,
//  and the dashboard stayed dead until the user found Reload.
//
//  The policy: reload automatically, but not forever. A page that kills its
//  own content process on load (a crash loop, or a page too heavy for the
//  device) would otherwise reload-and-die indefinitely, burning battery and
//  hiding the problem. After `maxReloads` within `window`, stop and show the
//  error page so a human sees it.
//
//  A termination while the app is in the background is not reloaded there:
//  WebKit cannot usefully load in a suspended app, and doing it on return to
//  the foreground puts the page back when it is needed. That deferred reload
//  counts against the same budget.
//
//  Pure Foundation, so `scripts/test-content-process-recovery.sh` compiles it
//  alone.
//

import Foundation

struct ContentProcessRecovery: Sendable {
    /// Reloads allowed within `window` before giving up (R7: 2 per 60 s).
    let maxReloads: Int
    let window: TimeInterval

    /// When recent automatic reloads happened, oldest first, pruned to
    /// `window`.
    private(set) var recentReloads: [Date] = []

    init(maxReloads: Int = 2, window: TimeInterval = 60) {
        self.maxReloads = maxReloads
        self.window = window
    }

    /// Records a termination at `now` and says whether to reload. A `true`
    /// consumes budget; a `false` means show the error page instead.
    mutating func shouldReload(now: Date) -> Bool {
        recentReloads.removeAll { now.timeIntervalSince($0) >= window }
        guard recentReloads.count < maxReloads else { return false }
        recentReloads.append(now)
        return true
    }
}
