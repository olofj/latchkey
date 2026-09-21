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
    /// No gateway: the dashboard shows the gateway picker (M5) until one is
    /// chosen. Until M5 this was a hardcoded `https://byskebox.<tailnet>`.
    static let defaultURL = ""

    /// The current home-page URL. `@Published` so Settings' text field and the
    /// bookmarks sheet react to changes; the owning `Workspace` persists
    /// changes back into its definition.
    @Published var url: String

    init(url: String) {
        self.url = url
    }

    /// Whether a gateway has been chosen.
    var hasGateway: Bool { !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
