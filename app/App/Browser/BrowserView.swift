// Copyright (c) Tailscale Inc & contributors
// SPDX-License-Identifier: BSD-3-Clause

//  Created by Jonathan Nobels on 2025-12-16.
//

import SwiftUI
import WebKit

struct BrowserView: View {
    @ObservedObject var model: BrowserViewModel

    init(model: BrowserViewModel) {
        self.model = model
    }

    var body: some View {
        Group {
            if let navError = model.navError {
                // A failed navigation replaces the page, like a conventional
                // browser error document. Because no old page remains visible,
                // the chrome may safely show the attempted URL.
                NavErrorPage(
                    urlString: model.navErrorURLString ?? navError.url?.absoluteString ?? "",
                    kind: model.navErrorKind,
                    message: model.navErrorMessage
                )
            } else {
                // The owned WKWebView extends beneath the notch/Dynamic Island.
                // Pages using viewport-fit=cover can consume the real CSS safe-
                // area values, matching Safari's edge-to-edge model.
                RawWebView(model: model)
                    // A WKWebView belongs to exactly one tab; prevent
                    // UIViewRepresentable from reusing the previous tab's view.
                    .id(ObjectIdentifier(model))
                    .ignoresSafeArea(.container, edges: .top)
            }
        }
        // Cover the instant before UIViewRepresentable installs WKWebView with
        // the same adaptive background used by RawWebView itself.
        .background(Color.platformSystemBackground)
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
    let urlString: String
    let kind: NavErrorKind?
    let message: String?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.orange)
                .padding(.bottom, 4)
            Text("Unable to Load Page")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.primary)

            // Category label — distinguishes a URL format problem (the URL
            // itself is bad) from a retrieval problem (the URL is fine but we
            // couldn't reach it). Helps the user know whether to fix the URL
            // or check their connection.
            if let kind, let label = categoryLabel(for: kind) {
                Text(label.text)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(label.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // The URL, escaped for diagnosis. Monospaced so the `\u{XXXX}`
            // sequences align and any unexpected characters stand out.
            VStack(alignment: .leading, spacing: 2) {
                Text("URL (escaped for debugging):")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(debugEscaped(urlString))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }

            if let message, !message.isEmpty {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

        }
        .padding(32)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.platformSystemBackground)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("nav-error-overlay")
    }

    /// A short label + color for each error category, or nil for `.other`
    /// (page-closed / content-process crash — no useful category to show).
    /// The words are `NavErrorKind.caption`'s, host-tested; only the colour
    /// is decided here.
    private func categoryLabel(for kind: NavErrorKind) -> (text: String, color: Color)? {
        guard let text = kind.caption else { return nil }
        return (text, kind == .urlFormat ? .orange : .secondary)
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
