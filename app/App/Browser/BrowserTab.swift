// Copyright (c) Tailscale Inc & contributors
// SPDX-License-Identifier: BSD-3-Clause

//
//  BrowserTab.swift
//  Latchkey
//
//  The page record for the dashboard. Its WKWebView is created when shown
//  and can be released again; the URL and title are kept in memory only
//  (revision R2 — never written to disk).
//

import SwiftUI
import WebKit
import Combine
import TailscaleKit

@MainActor
final class BrowserTab: Identifiable, ObservableObject {
    let id: UUID
    let viewModel: BrowserViewModel
    let initialURL: URL
    private let model: TSNetModel

    @Published private(set) var displayTitle: String
    @Published private(set) var displayURL: String
    @Published private(set) var displayHost: String
    @Published private(set) var connectionType: ConnectionType = .internet

    private var cancellables: Set<AnyCancellable> = []

    /// The latest trimmed page title, held until the debounce fires or the
    /// page finishes loading (whichever comes first). Decouples the tab bar
    /// width from the page title churn that happens during load.
    private var pendingTitle: String = ""
    /// While loading, title commits are delayed by this interval so a title
    /// that changes several times mid-load only resizes the tab chip once.
    private static let titleDebounce: Duration = .milliseconds(300)
    private var titleDebounceTask: Task<Void, Never>?

    init(id: UUID = UUID(), model: TSNetModel, initialURL: URL,
         dataStore: WKWebsiteDataStore,
         isHomePage: Bool = false,
         session: SessionManager? = nil,
         openExternally: @escaping (URL) -> Void = { _ in },
         reportLoadFailure: ((SocksRelayRecovery.PageFailure) -> Void)? = nil) {
        self.id = id
        self.initialURL = initialURL
        self.model = model
        // Default to the hostname (not the app name) so a no-title page shows
        // where it is rather than "Latchkey".
        let initialHost = initialURL.host?.isEmpty == false
            ? initialURL.host!
            : initialURL.absoluteString
        self.displayTitle = initialHost
        self.displayURL = initialURL.absoluteString
        self.displayHost = initialURL.host ?? initialURL.absoluteString
        self.viewModel = BrowserViewModel(model: model, initialURL: initialURL,
                                          dataStore: dataStore,
                                          isHomePage: isHomePage,
                                          session: session,
                                          openExternally: openExternally,
                                          reportLoadFailure: reportLoadFailure)

        viewModel.$title
            .combineLatest(viewModel.$url)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in self?.refreshDisplayed() }
            .store(in: &cancellables)

        // When the page finishes loading, commit any pending title immediately
        // instead of waiting out the debounce timer.
        viewModel.$isLoading
            .receive(on: DispatchQueue.main)
            .sink { [weak self] loading in
                if !loading { self?.refreshDisplayed() }
            }
            .store(in: &cancellables)

        model.$localStatus
            .combineLatest(model.$proxyPolicy)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in self?.refreshConnectionType() }
            .store(in: &cancellables)
    }

    var hasWebView: Bool { viewModel.hasWebView }
    func unloadWebView() { viewModel.unloadWebView() }

    private func refreshDisplayed() {
        // Hold the latest trimmed title and commit it on a debounce while the
        // page is loading (the title churns during load and would jiggle the
        // tab bar), or immediately once the page is no longer loading.
        pendingTitle = viewModel.title.trimmingCharacters(in: .whitespacesAndNewlines)
        scheduleTitleCommit()

        let newURL = viewModel.url?.absoluteString ?? displayURL
        displayURL = newURL
        displayHost = viewModel.url?.host ?? URL(string: displayURL)?.host ?? ""
        refreshConnectionType()
    }

    /// Commits `pendingTitle` to `displayTitle` now if the page is not loading,
    /// or after a short debounce if it is. The debounce keeps the tab chip from
    /// resizing on every interim title change during load; the load-finished
    /// observer forces an immediate commit so the final title appears without
    /// waiting the full debounce.
    private func scheduleTitleCommit() {
        if viewModel.isLoading {
            titleDebounceTask?.cancel()
            titleDebounceTask = Task { [weak self] in
                try? await Task.sleep(for: Self.titleDebounce)
                guard !Task.isCancelled, let self else { return }
                self.commitTitle()
            }
        } else {
            titleDebounceTask?.cancel()
            titleDebounceTask = nil
            commitTitle()
        }
    }

    private func commitTitle() {
        let trimmed = pendingTitle
        if !trimmed.isEmpty {
            displayTitle = trimmed
        } else if let host = viewModel.url?.host, !host.isEmpty {
            // Pages with no <title> show where they are (the host) instead of
            // the app name, which was confusing.
            displayTitle = host
        } else if let host = URL(string: displayURL)?.host, !host.isEmpty {
            displayTitle = host
        } else {
            displayTitle = "Latchkey"
        }
    }

    private func refreshConnectionType() {
        connectionType = ConnectionTypeResolver.resolve(
            host: viewModel.url?.host ?? URL(string: displayURL)?.host ?? initialURL.host,
            status: model.localStatus,
            proxyPolicy: model.proxyPolicy
        )
    }
}
