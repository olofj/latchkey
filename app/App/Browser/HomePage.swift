// Copyright (c) Tailscale Inc & contributors
// SPDX-License-Identifier: BSD-3-Clause

//  HomePage.swift
//  Latchkey
//
//  The KiroCrew gateway this workspace opens. Persisted as part of the
//  workspace's `WorkspaceDefinition` (the `Workspace` observes `homePage.$url`
//  and writes it back).
//
//  Moved out of `App/Bookmarks/` when bookmarks were removed (PLAN §1.6); it
//  was the one thing in that directory worth keeping. The type name is
//  retained rather than renamed to `Gateway` because M5 introduces real
//  gateway types and two overlapping meanings of "gateway" would be worse
//  than one slightly dated name.
//

import Foundation
import SwiftUI
import Combine

@MainActor
final class HomePage: ObservableObject {
    /// The gateway loaded when the user hasn't chosen one.
    ///
    /// TEMPORARY (PLAN §1.7): hardcoded to Olof's primary gateway so M1 has a
    /// single destination to pin. M5 replaces this with the gateway chosen by
    /// `GatewayDiscovery`, and this constant becomes the last-resort fallback
    /// for a first run that discovers nothing.
    ///
    /// HTTPS because `byskebox` is fronted by `tailscale serve` on 443 with a
    /// real Let's Encrypt certificate for the MagicDNS name. `chonk` answers
    /// plain HTTP on :5476 instead; that asymmetry is M5.2's problem.
    static let defaultURL = "https://byskebox.example.ts.net"

    /// The current home-page URL. `@Published` so Settings' text field and the
    /// bookmarks sheet react to changes; the owning `Workspace` persists
    /// changes back into its definition.
    @Published var url: String

    init(url: String) {
        self.url = url
    }
}
