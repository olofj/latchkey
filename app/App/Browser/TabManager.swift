// Copyright (c) Tailscale Inc & contributors
// SPDX-License-Identifier: BSD-3-Clause

//
//  TabManager.swift
//  Latchkey
//
//  Owns the workspace's single page and its WKWebView lifecycle. Latchkey
//  has no tabs (PLAN §1.4), so the cap is 1.
//
//  Nothing here is persisted (revision R2, finding H1). Upstream saved each
//  tab's URL to `tabs.json` and reopened it on cold launch, so a sign-in URL
//  — `https://<gateway>/?token=…` — was written to disk and replayed on the
//  next start. The page URL is not worth restoring anyway: the dashboard is a
//  single-page app that restores its own state from the server, and the
//  gateway origin is the only safe place to land. Every cold start opens it.
//

import Combine
import SwiftUI
import WebKit
import TailscaleKit

@MainActor
final class TabManager: ObservableObject {
    static let maximumTabCount = 1

    @Published private(set) var tabs: [BrowserTab] = []
    @Published private(set) var selectedIndex: Int = 0

    private let workspaceID: UUID
    private let model: TSNetModel
    private let homePage: HomePage
    private let dataStore: WKWebsiteDataStore

    /// Set by native macOS windows so closing the last tab closes the window
    /// (and, on reopen, a fresh home-page tab is created) instead of silently
    /// reopening the home page in place. iOS leaves this nil: the last tab
    /// closes back to a fresh home-page tab (there's no window to close).
    var onLastTabClosed: (() -> Void)?

    var currentTab: BrowserTab? {
        guard tabs.indices.contains(selectedIndex) else { return nil }
        return tabs[selectedIndex]
    }

    var tabCount: Int { tabs.count }
    var canOpenNewTab: Bool { tabs.count < Self.maximumTabCount }

    init(workspaceID: UUID, model: TSNetModel, homePage: HomePage,
         dataStore: WKWebsiteDataStore) {
        self.workspaceID = workspaceID
        self.model = model
        self.homePage = homePage
        self.dataStore = dataStore

        // A build before R2 may have left a tabs.json holding a sign-in URL.
        // Delete it rather than read it.
        WorkspaceStore.removeTabs(workspaceID)
        _ = openChatTab(select: true)
    }

    @discardableResult
    func openChatTab(select: Bool = true) -> BrowserTab? {
        let url = URL(string: homePage.url) ?? URL(string: HomePage.defaultURL)!
        return openTab(url: url, select: select, isHomePage: true)
    }

    /// Opens a page requested by web content (target=_blank/window.open) in
    /// this workspace, preserving the same website data store and proxy.
    @discardableResult
    func openTab(url: URL, select: Bool = true, isHomePage: Bool = false) -> BrowserTab? {
        guard canOpenNewTab else { return nil }
        let tab = makeTab(url: url, isHomePage: isHomePage)
        tabs.append(tab)
        if select {
            selectedIndex = tabs.count - 1
            unloadHiddenTabs()
        }
        return tab
    }

    func select(_ tab: BrowserTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        selectedIndex = index
        unloadHiddenTabs()
    }

    func closeTab(_ tab: BrowserTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tab.unloadWebView()
        tabs.remove(at: index)

        if tabs.isEmpty {
            if let onLastTabClosed {
                onLastTabClosed()
                return
            }
            _ = openChatTab(select: true)
            return
        }
        if selectedIndex > tabs.count - 1 {
            selectedIndex = tabs.count - 1
        } else if index < selectedIndex {
            selectedIndex -= 1
        }
        unloadHiddenTabs()
    }

    func closeCurrentTab() {
        guard let currentTab else { return }
        closeTab(currentTab)
    }

    func selectPreviousTab() {
        guard !tabs.isEmpty else { return }
        selectedIndex = (selectedIndex - 1 + tabs.count) % tabs.count
        unloadHiddenTabs()
    }

    func selectNextTab() {
        guard !tabs.isEmpty else { return }
        selectedIndex = (selectedIndex + 1) % tabs.count
        unloadHiddenTabs()
    }

    /// Called when its workspace leaves the visible pane.
    func unloadAllWebViews() {
        for tab in tabs { tab.unloadWebView() }
    }

    private func unloadHiddenTabs() {
        for (index, tab) in tabs.enumerated() where index != selectedIndex {
            tab.unloadWebView()
        }
    }

    private func makeTab(url: URL, isHomePage: Bool = false) -> BrowserTab {
        BrowserTab(model: model, initialURL: url,
                   dataStore: dataStore,
                   isHomePage: isHomePage,
                   openExternally: { url in Self.openExternally(url) })
    }

    /// Hands a URL to the system: Safari for web links, the owning app for
    /// mailto:, tel: and the like. Reached for anything `NavigationPolicy`
    /// sends out of the app (R3), and from the context menu's "Open in
    /// Safari".
    ///
    /// Upstream opened a second tab. With `maximumTabCount == 1` that path now
    /// hits `canOpenNewTab == false` and returns nil, which means such a link
    /// would do **nothing at all** when tapped: no new tab, no navigation, no
    /// error. Silently dead links are worse than either alternative.
    ///
    /// Safari rather than this tab, deliberately. The KiroCrew dashboard links
    /// out to GitHub, docs and the like; loading those here would replace the
    /// session the user was reading, and with no address bar and no back
    /// button there is no way back. PLAN §1.3 also rules out being a general
    /// browser — an external link is exactly the case that belongs elsewhere.
    private static func openExternally(_ url: URL) {
#if canImport(UIKit)
        // NavigationPolicy never sends these here; refuse them anyway, since
        // they could only reach this point through a bug.
        let scheme = url.scheme?.lowercased() ?? ""
        guard !["javascript", "data", "file", "blob", "about"].contains(scheme) else {
            logger.log("Refusing to open a \(scheme): URL externally")
            return
        }
        // http(s) goes to Safari; mailto:, tel: and friends to their apps.
        logger.log("Opening externally: \(url.redactedForLog)")
        UIApplication.shared.open(url)
#endif
    }

}
