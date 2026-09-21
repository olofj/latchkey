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
}
