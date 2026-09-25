// Copyright (c) Tailscale Inc & contributors
// SPDX-License-Identifier: BSD-3-Clause

//  Created by Jonathan Nobels on 2025-12-16.
//

import SwiftUI
import WebKit

struct BrowserView: View {
    @ObservedObject var model: BrowserViewModel
    /// D3: the chosen gateway is not in the tailnet. The banner above owns the
    /// affordances; this only changes what the empty body says.
    var gatewayMissing: Bool = false
    /// Stops the load and opens the picker. One presentation path, owned by
    /// `DashboardContent` (M5 review), so Find, Change, the connecting hint and
    /// the error page cannot produce two overlapping sheets.
    var onChooseGateway: () -> Void = {}

    init(model: BrowserViewModel, gatewayMissing: Bool = false,
         onChooseGateway: @escaping () -> Void = {}) {
        self.model = model
        self.gatewayMissing = gatewayMissing
        self.onChooseGateway = onChooseGateway
    }

    var body: some View {
        // A ZStack, not a Group with an `if`: the web view stays in the
        // hierarchy in EVERY state (F4 §4.6). The old `if navError` branch
        // removed it, which tears down the very load being described and costs
        // a makeUIView on every retry.
        ZStack {
            // The web view is laid out INSIDE the top safe area, as it already
            // is at the bottom (F9 §0). It used to ignore it and extend under
            // the notch/Dynamic Island, which handed a viewport-fit=cover page
            // a 62pt inset it was trusted to honour — and a page that is not
            // an installed web app has every reason not to (KiroCrew 0.7.0
            // honours it only under display-mode: standalone). Now nothing is
            // above the page, it is told 0, and its y=0 is below the island
            // whatever CSS the gateway ships. Do not add
            // `.ignoresSafeArea(.container, edges: .top)` back; L1's
            // testInsetProbesReportWhatThePageIsTold fails if you do. Since
            // F15 the app bar sits between the safe-area top and this view.
            RawWebView(model: model)
                // A WKWebView belongs to exactly one tab; prevent
                // UIViewRepresentable from reusing the previous tab's view.
                .id(ObjectIdentifier(model))
                // Out of the accessibility tree while a state page covers it.
                // SwiftUI orders siblings by position, and the web view now
                // starts 62pt below the full-screen state page, so it sorts
                // AFTER it and wins the accessibility hit test: VoiceOver (and
                // XCUITest's isHittable) reached the web view through the error
                // page's buttons. Drawing order was never the problem.
                .accessibilityHidden(!model.pageState.leavesWebViewUncovered)
            PageStateView(state: model.pageState,
                          gatewayMissing: gatewayMissing,
                          onRetry: { model.reload() },
                          onChooseGateway: onChooseGateway)
        }
        // The strip between the island and the page, and the app bar in it,
        // take the page's canvas colour from `AppBarColumn` (F15), which owns
        // everything above the web view now. The window safe-area probe that
        // was overlaid on this view's corner lives in `DashboardContent`'s
        // background: it reads the window, so it never needed to sit on the page.
    }
}

/// The full-page error document shown in place of web content when navigation
/// fails. The `nav-error-overlay` identifier is retained for UI-test
/// compatibility even though this is no longer an overlay or modal card.
///
/// The URL is rendered **escaped** (via `debugEscaped`) so invisible or
/// problematic characters the keyboard may have injected — non-breaking space
/// (U+00A0), zero-width space (U+200B), smart quotes (U+201C/201D), tabs,
/// newlines, etc. — are visible as `\u{XXXX}` instead of silently breaking the
/// URL. `kind` distinguishes a URL **format** error (parse/validation rejected)
/// from a **retrieval** error (couldn't connect) via a small category label
/// (`NavErrorKind.caption`, host-tested): a SOCKS failure, which WebKit
/// reports as -1000 "bad URL", reads "Connection error", never "URL format
/// error" (F4 §4.3; the page itself is rebuilt by F4 §3.2).
struct NavErrorPage: View {
    let failure: PageState.Failure
    var onRetry: () -> Void = {}
    var onChooseGateway: () -> Void = {}

    @State private var showingDetails = false

    var body: some View {
        let lines = PageFailureText.lines(for: failure)
        return VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.orange)
            Text(lines.title)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("nav-error-title")
            Text(lines.cause)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("nav-error-cause")
            Text(lines.next)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("nav-error-next")

            // Full opacity, over an opaque background: a control at opacity < 1
            // over a WKWebView receives no taps (M8). Both buttons exist in
            // every failure, because "try again" and "use a different gateway"
            // are the only two things the owner can actually do.
            HStack(spacing: 12) {
                Button("Try again", action: onRetry)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("nav-error-retry")
                Button("Choose another gateway", action: onChooseGateway)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("nav-error-choose-gateway")
            }

            // Collapsed: the diagnosis is read here when it is wanted, and D1
            // means it is read HERE rather than sent anywhere.
            DisclosureGroup("Details", isExpanded: $showingDetails) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(PageFailureText.details(for: failure, urlString: urlString), id: \.self) { line in
                        Text(line)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
            }
            .font(.footnote)
            .accessibilityIdentifier("nav-error-details")
        }
        .padding(32)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.platformSystemBackground)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("nav-error-overlay")
    }

    /// The URL for Details. Never the sign-in token: `BrowserViewModel` strips
    /// it before the failure is built, and this reads only what it was given.
    private var urlString: String {
        failure.fqdn.isEmpty ? "" : "https://\(PageFailureText.displayHost(failure.fqdn, port: failure.port))/"
    }
}

// `debugEscaped` lived here until F4. It moved to `PageFailureText.swift`, and
// became `nonisolated`, for two reasons: the failure wording that calls it is
// pure and host-compiled, and this file is a SwiftUI view the host test cannot
// build. Leaving a copy behind is what the first attempt did, and the duplicate
// declaration failed the build.

struct LoadingView: View {
    var body: some View {
        VStack {
            Text("Connecting to your Tailnet...")
            ProgressView()
        }
    }
}
