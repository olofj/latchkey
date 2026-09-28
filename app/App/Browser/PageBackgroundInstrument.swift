// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

//
//  PageBackgroundInstrument.swift
//  Latchkey
//
//  F21 §6: every canvas colour the page reported since its document
//  committed, in order, for the session suite. The shell's dark default
//  paints for a frame or a few hundred ms; a poll of the strip's colour
//  would miss it, this list does not.
//
//  Testing builds only, and only under `-UITestReportPageBackgrounds`, so
//  no other suite's sweep of the screen ever meets it. A test instrument,
//  never a control: one point of text in the top-leading corner of the
//  status-bar strip, as `DashboardContent`'s instruments are, not over the
//  page.
//

import SwiftUI

extension View {
    /// Adds `page-background-reports` for `model`, when asked for.
    func pageBackgroundInstrument(_ model: BrowserViewModel) -> some View {
#if LATCHKEY_TEST_HOOKS
        background(alignment: .topLeading) {
            if TestHooks.flag("-UITestReportPageBackgrounds") {
                PageBackgroundReports(model: model)
            }
        }
#else
        self
#endif
    }
}

#if LATCHKEY_TEST_HOOKS
private struct PageBackgroundReports: View {
    @ObservedObject var model: BrowserViewModel

    var body: some View {
        // `""` in the list is a canvas that paints nothing.
        Text("page-backgrounds:" + model.pageBackgroundReports.joined(separator: "|"))
            .accessibilityIdentifier("page-background-reports")
            .font(.system(size: 1))
            .lineLimit(1)
            .opacity(0.01)
            .allowsHitTesting(false)
            .ignoresSafeArea()
    }
}
#endif
