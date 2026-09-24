// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

//
//  PopupCatcher.swift
//  Latchkey
//
//  Catches a `window.open()` that starts blank and learns its destination
//  later (revision R3 review follow-up).
//
//  KiroCrew opens windows that way in several places — for example
//  `let n = window.open('', '_blank'); … await api(); n.location = url` for a
//  Drive download — because a popup blocker only permits `window.open` inside
//  the click handler, before the async call. Latchkey has one web view, so
//  its UI delegate cannot hand back a real second window. Returning nil makes
//  `window.open` return null, and every such action silently does nothing.
//
//  So WebKit gets a throwaway, never-displayed web view instead. The page
//  scripts it as usual. The first time it tries to go somewhere real, the
//  catcher cancels that navigation, hands the URL to `route` — which applies
//  `NavigationPolicy` exactly as for any other top-level navigation — and
//  retires. A popup that never navigates is dropped after `lifetime`.
//

import WebKit

@MainActor
final class PopupCatcher: NSObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    private let route: (URL) -> Void
    private let finish: (PopupCatcher) -> Void
    private var finished = false
    private var expiry: Task<Void, Never>?

    /// How long a blank popup may wait for its destination. KiroCrew sets it
    /// after an API round trip, so this is generous.
    static let lifetime: Duration = .seconds(60)

    /// - Parameters:
    ///   - configuration: the configuration WebKit passed to
    ///     `createWebViewWith`. WebKit requires the returned view to be built
    ///     from exactly this object.
    ///   - route: called once with the popup's first real destination.
    ///   - finish: called once when the catcher is done, so the owner can
    ///     release it.
    init(configuration: WKWebViewConfiguration,
         route: @escaping (URL) -> Void,
         finish: @escaping (PopupCatcher) -> Void) {
        self.webView = WKWebView(frame: .zero, configuration: configuration)
        self.route = route
        self.finish = finish
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        expiry = Task { [weak self] in
            try? await Task.sleep(for: Self.lifetime)
            guard !Task.isCancelled else { return }
            logger.log("PopupCatcher: blank popup never navigated; dropping it")
            self?.retire()
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url,
              !Self.isBlank(url)
        else {
            // The initial about:blank load, which the page needs in order to
            // script the window at all.
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        guard !finished else { return }
        logger.log("PopupCatcher: popup destination \(url.redactedForLog)")
        route(url)
        retire()
    }

    func webViewDidClose(_ webView: WKWebView) {
        retire()
    }

    /// A popup asking for a popup of its own: refuse. Nothing legitimate in
    /// the dashboard needs a second level.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        nil
    }

    nonisolated static func isBlank(_ url: URL) -> Bool {
        let s = url.absoluteString
        return s.isEmpty || s == "about:blank"
    }

    private func retire() {
        guard !finished else { return }
        finished = true
        expiry?.cancel()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        finish(self)
    }
}
