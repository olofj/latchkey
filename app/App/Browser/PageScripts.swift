// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

//
//  PageScripts.swift
//  Latchkey
//
//  The `WKUserScript`s installed into the dashboard's web view. Their source
//  lives in PageScriptSources.swift so it can be tested on the host.
//
//  Every script here is main-frame only unless it says why not (revision R3):
//  the dashboard renders widgets in same-origin `/sandbox-doc/` iframes, and
//  nothing in this app has any business running inside them.
//

import WebKit

enum PageScripts {
    /// See `PageScriptSources.stripSignInToken`.
    static var stripSignInToken: WKUserScript {
        WKUserScript(source: PageScriptSources.stripSignInToken,
                     injectionTime: .atDocumentStart,
                     forMainFrameOnly: true)
    }

    /// Installs every script the dashboard gets. Called once per web view,
    /// before its first navigation.
    static func install(into controller: WKUserContentController) {
        controller.addUserScript(stripSignInToken)
    }

    /// The app's own world for `PageScriptSources.pageBackground`, so the
    /// handler it posts to is invisible to the page.
    static let pageBackgroundWorld = WKContentWorld.world(name: "latchkey-page-background")

    /// Installs the page-background reporter (F9 §0.1 step 2). `onChange`
    /// gets each distinct report, main frame only. Called once per web view,
    /// before its first navigation.
    static func installPageBackground(into controller: WKUserContentController,
                                      onChange: @escaping (String) -> Void) {
        controller.addUserScript(WKUserScript(source: PageScriptSources.pageBackground,
                                              injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true,
                                              in: pageBackgroundWorld))
        controller.add(PageBackgroundHandler(onChange), contentWorld: pageBackgroundWorld,
                       name: PageScriptSources.pageBackgroundHandler)
    }
}

/// Holds a closure rather than the model: WKUserContentController retains its
/// handlers, and the closure captures the model weakly.
private final class PageBackgroundHandler: NSObject, WKScriptMessageHandler {
    let onChange: (String) -> Void
    init(_ onChange: @escaping (String) -> Void) { self.onChange = onChange }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let css = message.body as? String else { return }
        onChange(css)
    }
}
