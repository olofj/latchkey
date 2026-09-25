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
//  nothing in this app has any business running inside them. The two
//  exceptions, F6's blocked-image marker and F17's click reporter, say why.
//
//  Order, as `BrowserViewModel.makeWebView` installs them: R2's token strip,
//  F6's marker, F17's click reporter, the page-background reporter, the app
//  bar's observer, then the session bridge. Each is an IIFE in its own world, so the order does
//  not matter functionally; it is fixed so nobody has to wonder. F5's
//  chip-row style is the one added later, at the first load of an origin,
//  because it carries that origin. No code
//  path removes a user script at runtime (`removeAllUserScripts` removes
//  every one of them, the M1 finding), and `removeAllContentRuleLists`
//  touches no script.
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

    /// The app's own world for `PageScriptSources.blockedMarker` (F6 §4.5):
    /// its `kiroBlocked` handler exists in this world only, so neither the
    /// page nor a widget frame inside it can post to it.
    static let blockedMarkerWorld = WKContentWorld.world(name: "latchkey-blocked")

    /// What the marker script reports (F6 §4a).
    enum BlockedMarkerMessage {
        /// A trusted tap on a marked image: the image's URL.
        case open(URL)
        /// Increments since the last report.
        case counts(blocked: Int, gatewayFailed: Int)
        /// Off-origin resources the page loaded, by origin, as increments.
        case hosts([String: Int])
    }

    /// Installs the blocked-image marker. Every frame, not main-frame only:
    /// agent images render inside same-origin widget frames, which is exactly
    /// where a marker is needed. `onMessage` gets each well-formed message
    /// with the frame that sent it; the caller checks the frame's origin.
    static func installBlockedMarker(into controller: WKUserContentController,
                                     onMessage: @escaping (BlockedMarkerMessage, WKFrameInfo) -> Void) {
        controller.addUserScript(WKUserScript(source: PageScriptSources.blockedMarker,
                                              injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false,
                                              in: blockedMarkerWorld))
        controller.add(BlockedMarkerHandler(onMessage), contentWorld: blockedMarkerWorld,
                       name: PageScriptSources.blockedMarkerHandler)
    }

    /// The app's own world for `PageScriptSources.activationReporter`.
    static let activationWorld = WKContentWorld.world(name: "latchkey-activation")

    /// Installs the trusted-click reporter (F17 §4.2). Every frame, like the
    /// marker: a tap inside a same-origin widget frame is still the owner's.
    /// `onClick` gets the frame the click was in; the caller checks its origin.
    static func installActivationReporter(into controller: WKUserContentController,
                                          onClick: @escaping (WKFrameInfo) -> Void) {
        controller.addUserScript(WKUserScript(source: PageScriptSources.activationReporter,
                                              injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false,
                                              in: activationWorld))
        controller.add(ActivationHandler(onClick), contentWorld: activationWorld,
                       name: PageScriptSources.activationHandler)
    }

    /// The app's own world for `PageScriptSources.chipRowStyle(origin:)`.
    static let chipRowWorld = WKContentWorld.world(name: "latchkey-chip-row")

    /// Adds the chip-row style for `origin` (F5 §6). Main frame only; the
    /// `<style>` it appends is DOM, so it applies whatever the world. Not
    /// before the first navigation but at the first load of `origin`
    /// (`BrowserViewModel.loadResolved`), which is where the qualified
    /// origin is known; a script added before `load` runs on that load.
    /// False when the origin is refused and nothing was added.
    static func installChipRowStyle(into controller: WKUserContentController, origin: String) -> Bool {
        guard let source = PageScriptSources.chipRowStyle(origin: origin) else { return false }
        controller.addUserScript(WKUserScript(source: source,
                                              injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true,
                                              in: chipRowWorld))
        return true
    }

    /// The app's own world for `PageScriptSources.appBarObserver`.
    static let appBarWorld = WKContentWorld.world(name: "latchkey-app-bar")

    /// Installs the app bar's finger observer (F15 §4a). `onSample` gets each
    /// touch-down, move and lift, and each change of the page's scroll
    /// range, main frame only. Called once per web view,
    /// before its first navigation.
    static func installAppBarObserver(into controller: WKUserContentController,
                                      onSample: @escaping (AppBarRetraction.Sample) -> Void) {
        controller.addUserScript(WKUserScript(source: PageScriptSources.appBarObserver,
                                              injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true,
                                              in: appBarWorld))
        controller.add(AppBarHandler(onSample), contentWorld: appBarWorld,
                       name: PageScriptSources.appBarHandler)
    }
}

/// Decodes the observer's posts. Anything malformed is dropped: the bar's
/// safe state is shown, and a sample that is not understood changes nothing.
private final class AppBarHandler: NSObject, WKScriptMessageHandler {
    let onSample: (AppBarRetraction.Sample) -> Void
    init(_ onSample: @escaping (AppBarRetraction.Sample) -> Void) { self.onSample = onSample }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any],
              let phase = body["p"] as? String else { return }
        switch phase {
        case "s": onSample(.began)
        case "e": onSample(.ended)
        case "m":
            guard let dx = (body["dx"] as? NSNumber)?.doubleValue,
                  let dy = (body["dy"] as? NSNumber)?.doubleValue,
                  let range = (body["r"] as? NSNumber)?.doubleValue,
                  dx.isFinite, dy.isFinite, range.isFinite else { return }
            onSample(.moved(dx: dx, dy: dy, scrollRange: range))
        case "x":
            guard let range = (body["r"] as? NSNumber)?.doubleValue, range.isFinite else { return }
            onSample(.extent(range))
        default: return
        }
    }
}

/// Decodes the marker's posts. Anything malformed is dropped. Only http(s)
/// URLs are passed on for `open`: the script sets the attribute from an
/// http(s) source, and a page that forged one is still held to it here.
private final class BlockedMarkerHandler: NSObject, WKScriptMessageHandler {
    let onMessage: (PageScripts.BlockedMarkerMessage, WKFrameInfo) -> Void
    init(_ onMessage: @escaping (PageScripts.BlockedMarkerMessage, WKFrameInfo) -> Void) {
        self.onMessage = onMessage
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let event = body["event"] as? String else { return }
        switch event {
        case "open":
            guard let raw = body["url"] as? String, let url = URL(string: raw),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
            onMessage(.open(url), message.frameInfo)
        case "counts":
            let blocked = (body["blocked"] as? NSNumber)?.intValue ?? 0
            let failed = (body["gatewayFailed"] as? NSNumber)?.intValue ?? 0
            guard blocked >= 0, failed >= 0, blocked + failed > 0 else { return }
            onMessage(.counts(blocked: blocked, gatewayFailed: failed), message.frameInfo)
        case "hosts":
            guard let raw = body["hosts"] as? [String: Any] else { return }
            var hosts: [String: Int] = [:]
            for (origin, n) in raw {
                guard let n = (n as? NSNumber)?.intValue, n > 0 else { continue }
                hosts[origin] = n
            }
            guard !hosts.isEmpty else { return }
            onMessage(.hosts(hosts), message.frameInfo)
        default:
            return
        }
    }
}

/// The body carries nothing: the message itself is the signal.
private final class ActivationHandler: NSObject, WKScriptMessageHandler {
    let onClick: (WKFrameInfo) -> Void
    init(_ onClick: @escaping (WKFrameInfo) -> Void) { self.onClick = onClick }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        onClick(message.frameInfo)
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
