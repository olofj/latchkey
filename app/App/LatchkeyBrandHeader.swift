// Copyright (c) Tailscale Inc & contributors
// SPDX-License-Identifier: BSD-3-Clause

//
//  LatchkeyBrandHeader.swift
//  Latchkey
//
//  A compact, centered brand lockup shown at the top of the connection gate.
//
//  Upstream drew Tailscale's aperture icon and wordmark here. Those are
//  Tailscale's marks and this is not their app, so Latchkey uses an SF Symbol
//  and a text wordmark instead. Deliberately plain: M8.1 designs real artwork,
//  and a placeholder that looks finished is worse than one that does not.
//
//  An optional `trailing` view (the Settings gear) is pinned to the trailing
//  edge while the lockup stays visually centered — this lets the main screen
//  drop its navigation bar without losing access to Settings.
//

import SwiftUI

struct LatchkeyBrandHeader<Trailing: View>: View {
    @ViewBuilder var trailing: () -> Trailing

    init(@ViewBuilder trailing: @escaping () -> Trailing) {
        self.trailing = trailing
    }

    var body: some View {
        ZStack {
            // Centered logo: app icon + wordmark.
            HStack(spacing: 10) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.tint)

                Text("Latchkey")
                    .font(.system(size: 21, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Latchkey")
            .accessibilityIdentifier("latchkey-brand-header")

            // Trailing control (e.g. Settings gear), pinned to the trailing
            // edge. Kept outside the centered logo's accessibility element so
            // it remains independently tappable/identifiable.
            HStack {
                Spacer()
                trailing()
            }
        }
    }
}

/// Convenience initializer for a header with no trailing control.
extension LatchkeyBrandHeader where Trailing == EmptyView {
    init() {
        self.init { EmptyView() }
    }
}
