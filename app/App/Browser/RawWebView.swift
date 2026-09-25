// Copyright (c) Tailscale Inc & contributors
// SPDX-License-Identifier: BSD-3-Clause

//
//  RawWebView.swift
//  Latchkey
//
//  SwiftUI bridge for the tab's owned WKWebView. Keeping the actual UIKit view
//  gives WebKit the exact frame SwiftUI assigns to the browser region and lets
//  its native keyboard, viewport, and safe-area handling work together.
//

import SwiftUI
import WebKit

#if canImport(UIKit)
struct RawWebView: UIViewRepresentable {
    @ObservedObject var model: BrowserViewModel
    @Environment(\.colorScheme) private var colorScheme

    func makeUIView(context: Context) -> WKWebView {
        let webView = model.makeWebView()
        applyThemeBackground(to: webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        model.attach(webView)
        applyThemeBackground(to: webView)
    }

    /// WKWebView otherwise flashes its default white backing store before the
    /// first document paints. Set both the view and under-page colors so fresh
    /// startup and later new tabs match the active appearance consistently.
    private func applyThemeBackground(to webView: WKWebView) {
        let color: UIColor = colorScheme == .dark ? .black : .white
        webView.isOpaque = true
        webView.backgroundColor = color
        webView.scrollView.backgroundColor = color
        webView.underPageBackgroundColor = color
    }
}

#if LATCHKEY_TEST_HOOKS
/// L1's instrument for F9 §0.2 (`-UITestReportSafeArea`): an accessibility
/// element whose value is the WINDOW's safe-area top, read live when the test
/// asks. XCUITest can see the web view's frame but not the window's safe area,
/// and the assertion is that the one starts at the other.
///
/// `.bottom` is F11 §6's: the gate's sign-in button must end above the home
/// indicator. It is a second element (`window-safe-area-bottom`, value
/// `bottom=N`) so the top probe's value keeps the shape its readers parse.
struct WindowSafeAreaProbe: UIViewRepresentable {
    var edge: VerticalEdge = .top

    func makeUIView(context: Context) -> UIView { ProbeView(edge: edge) }
    func updateUIView(_ view: UIView, context: Context) {}

    private final class ProbeView: UIView {
        let edge: VerticalEdge

        init(edge: VerticalEdge) {
            self.edge = edge
            super.init(frame: .zero)
            isAccessibilityElement = true
            accessibilityIdentifier = edge == .top ? "window-safe-area" : "window-safe-area-bottom"
            isUserInteractionEnabled = false
        }
        required init?(coder: NSCoder) { fatalError("not used") }

        override var accessibilityValue: String? {
            get {
                guard let window else { return "no-window" }
                return edge == .top
                    ? "top=\(Int(window.safeAreaInsets.top.rounded()))"
                    : "bottom=\(Int(window.safeAreaInsets.bottom.rounded()))"
            }
            set {}
        }
    }
}
#endif
#else
struct RawWebView: NSViewRepresentable {
    @ObservedObject var model: BrowserViewModel

    func makeNSView(context: Context) -> WKWebView {
        model.makeWebView()
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        model.attach(webView)
    }
}
#endif
