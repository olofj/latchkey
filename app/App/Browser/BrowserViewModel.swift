// Copyright (c) Tailscale Inc & contributors
// SPDX-License-Identifier: BSD-3-Clause

//  Created by Jonathan Nobels on 2025-12-16.

import SwiftUI
import Combine
import WebKit
import TailscaleKit

/// Broad category of a navigation error, so the error overlay can distinguish a
/// URL format problem from a retrieval problem.
enum NavErrorKind: Sendable, Equatable {
    case urlFormat
    case retrieval
    case other

    /// The category caption on the error page: today's words, as F4 §4.3
    /// specifies for the label fix that lands ahead of the page rebuild
    /// (§3.2 replaces them with "Couldn't reach <host>" and "Latchkey
    /// can't open this address"). Nil for `.other` (a content-process
    /// death, a policy interruption): no category helps. Here rather than
    /// in the view so the host test can pin which words a SOCKS failure gets.
    nonisolated var caption: String? {
        switch self {
        case .urlFormat: return "URL format error"
        case .retrieval: return "Connection error"
        case .other: return nil
        }
    }
}

/// Browser state backed by an owned `WKWebView`. Its UIKit frame, scroll view,
/// navigation lifecycle, and committed URL remain available to the app.
@MainActor
final class BrowserViewModel: NSObject, ObservableObject {
    @Published var failedInitialURL: URL?
    @Published var navError: (err: Error, url: URL?)?
    @Published var navErrorMessage: String?
    /// Set when `decidePolicyFor navigationResponse` refused a main-frame 5xx,
    /// read once by `handlePolicyInterruption`, which sees only WebKit's
    /// error 102 and cannot otherwise tell a refused response from a refused
    /// redirect (F4 §4.13).
    private var refusedResponseStatus: Int?
    @Published var navErrorKind: NavErrorKind?
    @Published var navErrorURLString: String?

    // MARK: - Page state (F4 §4.2, §4.3)

    /// What the page is doing, as one value. The views read this; the
    /// `navError*` fields above are what the error overlay read before F4 and
    /// are still set beside it, so this commit changes no visible behaviour.
    @Published private(set) var pageState: PageState = .idle

    /// How many times the page has entered `connecting` (F4 §4.7). Test builds
    /// read it through `page-connecting-shown-count`: a block that appears and
    /// vanishes between two polls is invisible to a test but not to a counter,
    /// which is exactly the flicker the 300 ms show-delay could introduce.
    @Published private(set) var connectingShownCount = 0

    /// Every transition writes one line (F4 §4.9), so a device run and a suite
    /// can both say which state was on screen and for how long. Assigning the
    /// same state twice is not logged: `@Published` fires `objectWillChange`
    /// even for an equal value, and a status poll would otherwise print a line
    /// every five seconds.
    /// True while `makeWebView` runs, which SwiftUI calls from inside a view
    /// update (`RawWebView.makeUIView`). Mutating `@Published` state there earns
    /// "Publishing changes from within view updates is not allowed, this will
    /// cause undefined behavior" — one per launch, which is how it was noticed.
    private var isBuildingWebView = false

    private func setPageState(_ next: PageState) {
        guard next != pageState else { return }
        if isBuildingWebView {
            // Announce it one main-actor tick later. The LOAD is unaffected —
            // `webView.load` still runs synchronously — and only if nothing else
            // has moved the state meanwhile, so an instant failure is not
            // clobbered by a late `connecting`.
            let before = pageState
            Task { @MainActor [weak self] in
                guard let self, self.pageState == before else { return }
                self.setPageState(next)
            }
            return
        }
        pageState = next
        // A state page covers the web view: the bar stays, with the gear.
        appBar.setPageCovered(!next.leavesWebViewUncovered)
        switch next {
        case .idle:
            break
        case .holding(let host, _):
            logger.log("page-state: holding host=\(host)")
        case .connecting(let host, let port, let since, let attempt):
            // Counted on entry from another state, not on each retry: the retries
            // keep the same block on screen.
            if attempt == 1 { connectingShownCount += 1 }
            logger.log("page-state: connecting host=\(host) port=\(port) attempt=\(attempt)"
                       + (attempt > 1 ? " after \(PageState.elapsedSeconds(since: since)) s" : ""))
        case .committed:
            break   // logged with its status where the response is seen
        case .failed(let f):
            var line = "page-state: failed cause=\(f.cause.logName) code=\(f.code) "
                + "after \(PageState.milliseconds(f.elapsed)) ms"
            if let reply = f.proxyReply { line += " reply=\"\(reply.reply)\"" }
            logger.log(line)
        }
    }

    /// The failure for `error` on `failedURL`, with the relay's reply attached
    /// when it is plausibly about this very load.
    /// `elapsed` is measured from the load's start unless given: a parse failure
    /// and a crash of an already-committed page had no load in flight, and
    /// `navigationStartedAt` would then be the *previous* load's clock.
    private func pageFailure(error: NSError, failedURL: URL?,
                             cause overrideCause: PageState.Failure.Cause? = nil,
                             elapsed fixedElapsed: Duration? = nil,
                             contentType: String? = nil,
                             bodyLength: Int? = nil) -> PageState.Failure {
        let fqdn = failedURL?.host ?? ""
        let port = failedURL?.port ?? 443
        let elapsed = fixedElapsed ?? elapsedSinceNavigationStart()
        let reply = matchingProxyReply(fqdn: fqdn, port: port)
        let cause = overrideCause
            ?? PageFailureText.cause(domain: error.domain, code: error.code,
                                     proxyReply: reply, elapsed: elapsed)
        return PageState.Failure(host: Self.firstLabel(of: fqdn), fqdn: fqdn, port: port,
                                 cause: cause, elapsed: elapsed,
                                 domain: error.domain, code: error.code, proxyReply: reply,
                                 responseContentType: contentType, responseBodyLength: bodyLength)
    }

    /// The host as the owner knows it: `byskebox`, not
    /// `byskebox.example.ts.net`. The full name is kept in `fqdn` and shown
    /// under Details.
    nonisolated static func firstLabel(of host: String) -> String {
        host.split(separator: ".").first.map(String.init) ?? host
    }

    /// D2: the first load is waiting for the node's status or its peer list.
    /// `loadInitial` runs again on every status poll, so the FIRST hold's stamp
    /// is kept — otherwise the duration on screen would reset every five
    /// seconds and a wait that never ends would look like one that just began.
    private func holdPage(_ url: URL) {
        let host = Self.firstLabel(of: url.host ?? "")
        if case .holding(let h, _) = pageState, h == host { return }
        setPageState(.holding(host: host, since: .now))
    }

    private func elapsedSinceNavigationStart() -> Duration {
        .milliseconds(max(0, Int(Date().timeIntervalSince(navigationStartedAt) * 1000)))
    }

    /// The relay's last refusal, if it was for this host and port and arrived no
    /// earlier than this load began. Both conditions matter: a discovery sweep
    /// refuses twelve other hosts a second before the page's own attempt, and a
    /// refusal from the *previous* load would otherwise explain this one.
    private func matchingProxyReply(fqdn: String, port: Int) -> ProxyReply? {
        guard let reply = tsnetModel.lastProxyFailure, !fqdn.isEmpty,
              reply.target.caseInsensitiveCompare("\(fqdn):\(port)") == .orderedSame,
              reply.at >= navigationStartedAt
        else { return nil }
        return reply
    }

    // Raw WKWebView state consumed by browser chrome.
    @Published private(set) var title = ""
    /// Security-sensitive, user-visible URL. This advances after WebKit commits
    /// a document navigation, when the committed document makes a same-origin
    /// History API / fragment change, or after a failed navigation replaces
    /// web content with our own full-page error document. It never follows an
    /// in-flight cross-origin provisional request.
    @Published private(set) var url: URL?
    @Published private(set) var isLoading = false
    @Published private(set) var estimatedProgress = 0.0
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    /// The page's canvas colour as computed CSS (`PageScriptSources.
    /// pageBackground`), `""` until the page reports one. `BrowserView` tints
    /// the strip above the web view with it (F9 §0.1).
    @Published private(set) var pageBackgroundCSS = ""
    /// Whether the app bar is shown over this page (F15). Fed from the page
    /// script's finger samples and from `pageState`.
    let appBar = AppBarController()

    private var observers: [AnyCancellable] = []
    private var webViewObservations: [NSKeyValueObservation] = []
    private var tsnetModel: TSNetModel
    private let initialURL: URL
    private let isHomePage: Bool
    private let dataStore: WKWebsiteDataStore
    private let configureWebView: ((WKWebViewConfiguration) -> Void)?
    private let openExternally: (URL) -> Void
    /// Where a load that failed on transport is reported (R30): the tsnet
    /// manager, which decides whether its SOCKS relay listener needs
    /// restarting. Nil in harnesses that have no relay.
    private let reportLoadFailure: ((SocksRelayRecovery.PageFailure) -> Void)?
    /// When the current navigation began (R30). The relay is asked whether
    /// it accepted anything since.
    private var navigationStartedAt = Date()
    /// `TSNetModel.proxyEndpointGeneration` as of the configuration last
    /// applied (R30 review). The 5-s status poll republishes on any rule
    /// change; only a publication that moved this replaced the transport.
    private var appliedProxyEndpointGeneration: UInt64
    private var webView: WKWebView?
    /// The workspace's dashboard session (M4). Owned by the workspace.
    private weak var session: SessionManager?

    /// The only origin the main frame may show (revision R3). Set from the
    /// app's own resolved loads in `loadResolved`, never from page-initiated
    /// navigations, so a page cannot widen it. Taken from the resolved URL
    /// rather than the configured gateway because a bare configured name is
    /// expanded to its FQDN before loading.
    private var allowedOrigin: String?

    /// True while the page on screen was opened by a same-origin new-window
    /// request (KiroCrew's "pop out chat", "open in new tab"). With one window
    /// and no back button that page would otherwise strand the user, so the
    /// dashboard shows a way back while this is set.
    @Published private(set) var showsReturnToDashboard = false

    /// Blank popups waiting to learn where they are going (`PopupCatcher`).
    private var popupCatchers: [ObjectIdentifier: PopupCatcher] = [:]

    /// Budget for automatic reloads after the web content process dies (R7).
    private var contentRecovery = ContentProcessRecovery()
    /// Set when the content process died while the app was in the
    /// background; the reload happens on return to the foreground.
    private var reloadWhenActive = false

    private(set) var didLoadInitial = false
    private var pendingLoadURL: URL?
    /// The backend can publish Running a moment before its first SOCKS dial is
    /// usable. Only the automatic startup navigation gets this settling grace;
    /// user-initiated loads continue to surface failures immediately.
    private var startupLoad: (url: URL, deadline: ContinuousClock.Instant)?
    private var startupRetryTask: Task<Void, Never>?

    init(model: TSNetModel, initialURL: URL, dataStore: WKWebsiteDataStore,
         isHomePage: Bool = false,
         configureWebView: ((WKWebViewConfiguration) -> Void)? = nil,
         session: SessionManager? = nil,
         openExternally: @escaping (URL) -> Void = { _ in },
         reportLoadFailure: ((SocksRelayRecovery.PageFailure) -> Void)? = nil) {
        self.tsnetModel = model
        self.initialURL = initialURL
        self.isHomePage = isHomePage
        self.dataStore = dataStore
        self.configureWebView = configureWebView
        self.session = session
        self.openExternally = openExternally
        self.reportLoadFailure = reportLoadFailure
        self.appliedProxyEndpointGeneration = model.proxyEndpointGeneration
        super.init()

        if let proxy = model.proxyConfiguration {
            dataStore.proxyConfigurations = [proxy]
        }
        model.$proxyConfiguration
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] proxy in self?.applyProxy(proxy) }
            .store(in: &observers)

        // Running can arrive just before the first complete status response,
        // and vice versa. Re-evaluate on both publications so the initial
        // request is made only after the hostname check has an answer.
        model.$localStatus
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.loadInitial() }
            .store(in: &observers)
        model.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.loadInitial() }
            .store(in: &observers)

#if canImport(UIKit)
        // A content process that died in the background is reloaded when the
        // app comes back (R7).
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reloadIfContentProcessDiedInBackground() }
            .store(in: &observers)
#endif
    }

    var hasWebView: Bool { webView != nil }

    /// Creates the tab's one WKWebView when SwiftUI installs it in a real view
    /// hierarchy. Creating it here (rather than in the model initializer) keeps
    /// the existing first-tap/crashed-gesture workaround intact.
    func makeWebView() -> WKWebView {
        if let webView { return webView }
        // SwiftUI calls this from inside a view update; see `isBuildingWebView`.
        isBuildingWebView = true
        defer { isBuildingWebView = false }

        let configuration = Self.makeWebViewConfiguration(dataStore: dataStore)
        // Before any navigation, so they run at every document start.
        PageScripts.install(into: configuration.userContentController)
        PageScripts.installPageBackground(into: configuration.userContentController) { [weak self] css in
            guard let self, self.pageBackgroundCSS != css else { return }
            self.pageBackgroundCSS = css
        }
        PageScripts.installAppBarObserver(into: configuration.userContentController) { [weak self] sample in
            self?.appBar.observe(sample)
        }
        session?.install(into: configuration.userContentController, host: self)
        configureWebView?(configuration)

        let view = WKWebView(frame: .zero, configuration: configuration)
#if canImport(UIKit)
        // Match Safari's subtle feathering as content scrolls beneath the
        // status indicators. This is iOS 26's public scroll-edge effect, not a
        // hand-built blur/gradient overlay.
        view.scrollView.topEdgeEffect.style = .soft
#endif
        // Keep UIKit's default automatic adjustment: it is what insets
        // ordinary pages, and L1's plain inset probe pins it (F9 §0.1 step 4).
        // The web view is no longer laid out beneath the notch (F9 §0), so a
        // viewport-fit=cover page is told a top inset of 0 and needs none.
        attach(view)

        if let pendingLoadURL {
            self.pendingLoadURL = nil
            // This is a restored committed page, not a never-loaded tab. A
            // later proxy-policy publication must not replace it with initialURL.
            didLoadInitial = true
            loadResolved(pendingLoadURL)
        } else if let url {
            // The tab had committed a page but lost its pending-restore URL
            // (a transient state). Restore the committed page rather than
            // sending the tab back to its initial/home URL.
            didLoadInitial = true
            loadResolved(url)
        } else {
            loadInitial()
        }
        return view
    }

    /// The configuration every dashboard web view is built from. Static and
    /// WebKit-only so scripts/test-browser-view-model.sh can assert it on
    /// the host; the scripts and the session bridge are installed by the
    /// caller, which owns them.
    static func makeWebViewConfiguration(dataStore: WKWebsiteDataStore) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.upgradeKnownHostsToHTTPS = false
        // D1: nothing leaves the device but traffic to the gateway. WebKit's
        // fraudulent-website check (Safe Browsing) is ON by default and
        // submits every main-frame navigation to the system's fraud-check
        // service -- a non-gateway destination outside the split tunnel,
        // from a process scripts/check-no-log-upload.sh does not watch. It
        // sends hash prefixes, so no token leaves, but it is per-navigation
        // egress D1 forbids, for a browser that opens exactly one origin the
        // owner chose (R3). Off.
        configuration.preferences.isFraudulentWebsiteWarningEnabled = false
        return configuration
    }

    /// Releases the heavy page process/view when this tab is hidden. The tab's
    /// committed URL/title stay in BrowserTab's lightweight metadata and the
    /// page is recreated on demand when selected again.
    func unloadWebView() {
        guard let webView else { return }
        webView.stopLoading()
        startupRetryTask?.cancel()
        startupRetryTask = nil
        startupLoad = nil
        // `url` is our validated address-bar URL. Do not read WKWebView.url here:
        // at an unload boundary it could be exposing a provisional destination.
        if let url { pendingLoadURL = url }
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webViewObservations.removeAll()
        self.webView = nil
        isLoading = false
        estimatedProgress = 0
        canGoBack = false
        canGoForward = false
        didLoadInitial = false
        // The next makeWebView loads the page afresh anyway.
        reloadWhenActive = false
        appBar.documentChanged()
        // No web view, so no page: a stale `connecting` here would have the
        // restored tab show a spinner for a load that is not running.
        setPageState(.idle)
    }

    /// Keeps delegates/observation attached if SwiftUI reuses the view.
    func attach(_ view: WKWebView) {
        guard webView !== view else { return }
        webView = view
        view.navigationDelegate = self
        view.uiDelegate = self
        observeWebView(view)
    }

    private func observeWebView(_ view: WKWebView) {
        webViewObservations.removeAll()
        webViewObservations = [
            view.observe(\.url, options: [.initial, .new]) { [weak self] view, _ in
                Task { @MainActor [weak self] in self?.acceptSameDocumentURL(candidate: view.url) }
            },
            view.observe(\.title, options: [.initial, .new]) { [weak self] view, _ in
                Task { @MainActor [weak self] in self?.title = view.title ?? "" }
            },
            view.observe(\.isLoading, options: [.initial, .new]) { [weak self] view, _ in
                Task { @MainActor [weak self] in self?.isLoading = view.isLoading }
            },
            view.observe(\.estimatedProgress, options: [.initial, .new]) { [weak self] view, _ in
                Task { @MainActor [weak self] in self?.estimatedProgress = view.estimatedProgress }
            },
            view.observe(\.canGoBack, options: [.initial, .new]) { [weak self] view, _ in
                Task { @MainActor [weak self] in self?.canGoBack = view.canGoBack }
            },
            view.observe(\.canGoForward, options: [.initial, .new]) { [weak self] view, _ in
                Task { @MainActor [weak self] in self?.canGoForward = view.canGoForward }
            },
        ]
    }

    func applyProxy(_ proxy: ProxyConfiguration) {
        dataStore.proxyConfigurations = [proxy]
        let generation = tsnetModel.proxyEndpointGeneration
        let endpointReplaced = generation != appliedProxyEndpointGeneration
        appliedProxyEndpointGeneration = generation
        if !didLoadInitial {
            loadInitial()
            return
        }
        // The transport under the page was replaced: a relay listener restart
        // (R30) or a loopback recovery. A page that failed on that transport
        // gets the one retry the user would make; any other error page stays,
        // and a republication that only rescoped the rules (the status poll,
        // on a peer change) retries nothing (R30 review).
        guard endpointReplaced else { return }
        if let navError, SocksRelayRecovery.isTransportFailure(navError.err) {
            logger.log("Proxy endpoint replaced (generation \(generation)); retrying the failed page")
            reload()
        }
    }

    func loadInitial() {
        guard !didLoadInitial, tsnetModel.state == .Running else { return }

        // A tab that has already committed a page (or has a pending restore
        // URL captured at unload) must never be sent back to its initial/home
        // URL. `loadInitial` is only for the very first load of a tab that has
        // never committed; restoration of an unloaded tab's committed page is
        // handled by `makeWebView` via `pendingLoadURL`/`url`. Without this
        // guard, a status/state poll firing on an unloaded (didLoadInitial was
        // reset) but already-committed tab would reload its home page when the
        // user next selects it.
        if url != nil || pendingLoadURL != nil { return }

        var target = initialURL
        if isHomePage {
            switch HomePageAvailabilityChecker.initialLoadDecision(
                urlString: initialURL.absoluteString,
                status: tsnetModel.localStatus) {
            case .wait:
                logger.log("loadInitial: holding \(initialURL.redactedForLog) until home-page availability is known")
                holdPage(initialURL)
                return
            case .load(let decidedURL):
                if decidedURL != initialURL {
                    logger.log("Home page host is not in this tailnet; opening \(decidedURL.redactedForLog)")
                }
                target = decidedURL
            }
        }

        if needsPeerDataToRoute(target), tsnetModel.proxyPolicy?.hasPeerData != true {
            logger.log("loadInitial: holding \(target.redactedForLog) until tailnet peer data arrives")
            holdPage(target)
            return
        }
        didLoadInitial = true
        load(url: target, isAutomaticStartupLoad: true)
    }

    func load(url: URL) {
        load(url: url, isAutomaticStartupLoad: false)
    }

    /// Opens a link the user chose (the context menu), under the same rule as
    /// every page-initiated navigation (R3). `load(url:)` is for the app's own
    /// loads and would make the link's origin the trusted one.
    func openLink(_ url: URL) {
        switch NavigationPolicy.decide(url: url, isMainFrame: true, allowedOrigin: allowedOrigin) {
        case .allow:
            load(url: url)
        case .openExternally:
            openExternally(url)
        case .cancel:
            logger.log("Link refused by navigation policy: \(url.redactedForLog)")
        }
    }

    /// Applies `NavigationPolicy`, plus the one case the pure policy cannot
    /// see: a scheme this web view has its own `WKURLSchemeHandler` for is the
    /// app's own content (the proxy-bounce test harness serves `bounce-test:`).
    private func navigationDecision(for url: URL?, isMainFrame: Bool,
                                    in webView: WKWebView) -> NavigationDecision {
        if let scheme = url?.scheme,
           webView.configuration.urlSchemeHandler(forURLScheme: scheme) != nil {
            return .allow
        }
        return NavigationPolicy.decide(url: url, isMainFrame: isMainFrame,
                                       allowedOrigin: allowedOrigin)
    }

    private func load(url requestedURL: URL, isAutomaticStartupLoad: Bool) {
        if !isAutomaticStartupLoad {
            startupRetryTask?.cancel()
            startupRetryTask = nil
            startupLoad = nil
        }
        guard let target = resolveForTailnet(requestedURL) else {
            // resolveForTailnet already reported the error (unknown/ambiguous
            // tailnet host) and set navError.
            return
        }
        if isAutomaticStartupLoad {
            startupLoad = (target, ContinuousClock.now + .seconds(20))
        }
        clearNavError()
        guard webView != nil else {
            // Preserve an unloaded tab's committed URL. Automatic initial-load
            // attempts must not overwrite it while the tab has no WKWebView.
            if pendingLoadURL == nil { pendingLoadURL = target }
            return
        }
        loadResolved(target)
    }

    private func loadResolved(_ url: URL) {
        // App-initiated loads define what the main frame may show (R3). An
        // about:blank fallback leaves the previous origin in place, so the
        // gateway stays loadable after it.
        if let origin = GatewayAddress.origin(of: url.absoluteString) {
            allowedOrigin = origin
        }
        // Be deliberately patient with slow private services. This does not
        // delay explicit connection failures; it only extends how long an
        // otherwise-silent request may remain pending.
        navigationStartedAt = Date()
        // A startup retry keeps the FIRST attempt's clock, so the duration on
        // screen never restarts while the silent retries run (F4 §4.3).
        let host = Self.firstLabel(of: url.host ?? "")
        let port = url.port ?? 443
        if case .connecting(let h, let p, let since, let attempt) = pageState, h == host, p == port {
            setPageState(.connecting(host: h, port: p, since: since, attempt: attempt + 1))
        } else {
            setPageState(.connecting(host: host, port: port, since: .now, attempt: 1))
        }
        webView?.load(URLRequest(url: url, timeoutInterval: 120))
    }

    /// During initial connection only, retry immediate transport failures while
    /// tsnet settles instead of replacing the page with an error that requires
    /// a manual reload. Returns true when the failure has been consumed.
    private func retryStartupLoadIfAppropriate(_ error: Error, failedURL: URL) -> Bool {
        guard let startupLoad, startupLoad.url == failedURL,
              ContinuousClock.now < startupLoad.deadline,
              Self.isTransientStartupError(error)
        else { return false }

        startupRetryTask?.cancel()
        startupRetryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self,
                      let pending = self.startupLoad,
                      pending.url == failedURL,
                      ContinuousClock.now < pending.deadline
                else { return }
                logger.log("Startup page transport not ready; retrying \(failedURL.redactedForLog)")
                self.loadResolved(failedURL)
            } catch {
                return
            }
        }
        return true
    }

    nonisolated private static func isTransientStartupError(_ error: Error) -> Bool {
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return false }
        // WebKit maps any SOCKS CONNECT failure to badURL (-1000), so it is a
        // transport error here despite the misleading name.
        return [NSURLErrorBadURL,
                NSURLErrorTimedOut,
                NSURLErrorCannotFindHost,
                NSURLErrorCannotConnectToHost,
                NSURLErrorNetworkConnectionLost,
                NSURLErrorNotConnectedToInternet,
                NSURLErrorCannotLoadFromNetwork].contains(ns.code)
    }

    /// Stops an in-flight load because the owner is about to pick another
    /// gateway (F4 §3.1). The page moves to `failed(.stopped)` rather than back
    /// to idle, so cancelling the picker leaves an error page with *Try again*
    /// on it instead of the blank web view this whole feature exists to remove.
    func stopForGatewayChange() {
        startupRetryTask?.cancel()
        startupRetryTask = nil
        startupLoad = nil
        webView?.stopLoading()
        // Only from a state where something was actually in flight: stopping a
        // committed page would replace a perfectly good page with an error.
        switch pageState {
        case .connecting, .holding:
            let elapsed = elapsedSinceNavigationStart()
            logger.log("page-state: stopped after \(PageState.milliseconds(elapsed)) ms")
            setPageState(.failed(pageFailure(error: URLError(.cancelled) as NSError,
                                             failedURL: url ?? initialURL,
                                             cause: .stopped, elapsed: elapsed)))
        case .idle, .committed, .failed:
            break
        }
    }

    func reload() {
        // Retry the attempted URL shown in the error overlay. Do not ask
        // WKWebView to reload its still-committed old page: that mismatch is
        // both confusing and dangerous in browser chrome.
        //
        // Only a URL the navigation policy would allow here (R3). `load(url:)`
        // is the app's own path and makes its target's origin the trusted one,
        // so retrying a failed foreign URL through it would load that site in
        // place and trust it — the phishing opening R3 exists to close.
        // Anything else retries the gateway itself.
        if let failedURL = navError?.url {
            if NavigationPolicy.decide(url: failedURL, isMainFrame: true,
                                       allowedOrigin: allowedOrigin) == .allow {
                load(url: failedURL)
            } else {
                logger.log("Reload: not retrying off-gateway URL \(failedURL.redactedForLog); reloading the gateway")
                load(url: initialURL)
            }
            return
        }
        guard let webView else {
            load(url: initialURL)
            return
        }
        clearNavError()
        webView.reload()
    }

    func stopLoading() {
        webView?.stopLoading()
    }
    func goBack() { if webView?.canGoBack == true { webView?.goBack() } }
    func goForward() { if webView?.canGoForward == true { webView?.goForward() } }

    private func needsPeerDataToRoute(_ url: URL) -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return false }
        guard let host = url.host()?.lowercased(), !host.isEmpty else { return false }
        return !host.contains(".") && !host.contains(":")
    }

    /// Canonicalizes every known bare MagicDNS peer name to its FQDN. iOS
    /// applies proxy match rules to the literal URL host before DNS search-path
    /// expansion, so the rewrite is required for deterministic routing. A bare
    /// name absent from the complete peer list is rejected rather than leaked
    /// to public/system DNS.
    private func resolveForTailnet(_ url: URL) -> URL? {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host()?.lowercased(),
              !host.isEmpty, !host.contains("."), !host.contains(":")
        else { return url }

        guard let status = tsnetModel.localStatus else { return url }
        let result = TailnetHostnameQualifier.qualify(
            url,
            searchDomains: status.CurrentTailnet.map { [$0.MagicDNSSuffix] } ?? [],
            hosts: tailnetHostRecords(from: status)
        )
        switch result {
        case .unchanged(let unchanged):
            return unchanged
        case .qualified(let qualified):
            logger.log("Expanded known tailnet short name \(url.redactedForLog) -> \(qualified.redactedForLog)")
            return qualified
        case .unknown(let label):
            reportUnknownTailnetHost(label, attemptedURL: url)
            return nil
        case .ambiguous(let label, let candidates):
            reportAmbiguousTailnetHost(label, candidates: candidates, attemptedURL: url)
            return nil
        }
    }

    private func tailnetHostRecords(from status: IpnState.Status) -> [TailnetHostRecord] {
        var peers: [IpnState.PeerStatus] = Array(status.Peer?.values ?? [:].values)
        if let selfStatus = status.SelfStatus { peers.append(selfStatus) }
        return peers.map { TailnetHostRecord(shortName: $0.HostName, fullName: $0.DNSName) }
    }

    private func reportAmbiguousTailnetHost(_ host: String, candidates: [String], attemptedURL: URL) {
        logger.log("Ambiguous tailnet short name \(host): \(candidates.joined(separator: ", "))")
        let error = URLError(.cannotFindHost)
        navError = (error, attemptedURL)
        navErrorMessage = "More than one tailnet device matches “\(host)”: \(candidates.joined(separator: ", ")). Enter the full name."
        navErrorKind = .retrieval
        navErrorURLString = Self.withoutSignInToken(attemptedURL).absoluteString
        url = attemptedURL
        failedInitialURL = attemptedURL == initialURL ? attemptedURL : nil
        // No load was dispatched, so no clock: resolution failed first.
        setPageState(.failed(pageFailure(error: error as NSError, failedURL: attemptedURL,
                                         cause: .ambiguousHost(host, candidates),
                                         elapsed: .zero)))
    }

    private func reportUnknownTailnetHost(_ host: String, attemptedURL: URL) {
        logger.log("Unknown tailnet short name: \(host)")
        let error = URLError(.cannotFindHost)
        navError = (error, attemptedURL)
        navErrorMessage = "No device named “\(host)” exists in this tailnet. Check the name and try again."
        navErrorKind = .retrieval
        navErrorURLString = Self.withoutSignInToken(attemptedURL).absoluteString
        url = attemptedURL
        failedInitialURL = attemptedURL == initialURL ? attemptedURL : nil
        setPageState(.failed(pageFailure(error: error as NSError, failedURL: attemptedURL,
                                         cause: .unknownHost(host), elapsed: .zero)))
    }

    func navigationError(_ error: Error, for failedURL: URL) {
        // A failed sign-in load must not put its token on the error page, in
        // `url`, or into a ⌘R retry (M4 review).
        let url = Self.withoutSignInToken(failedURL)
        logger.log("Navigation error for \(url.redactedForLog): \(LogRedaction.describe(error))")
        navError = (error, url)
        navErrorMessage = Self.describe(error, for: url)
        navErrorKind = Self.categorize(error)
        navErrorURLString = url.absoluteString
        // The failed page has been replaced by our trusted error document, so
        // showing the attempted URL cannot disguise the previously rendered
        // origin. Slow/in-flight loads still retain the committed URL.
        self.url = url
        failedInitialURL = url == initialURL ? url : nil
        // Let the tsnet manager judge whether its relay listener is what
        // failed (R30). Only the error's identity goes: no URL leaves here.
        let ns = error as NSError
        setPageState(.failed(pageFailure(error: ns, failedURL: url)))
        reportLoadFailure?(SocksRelayRecovery.PageFailure(
            domain: ns.domain, code: ns.code, navigationStartedAt: navigationStartedAt))
    }

    func reportURLParseFailure(_ raw: String) {
        logger.log("URL parse failure (URL(string:) returned nil): \(LogRedaction.scrub(raw))")
        navError = (URLError(.badURL), nil)
        navErrorMessage = "The URL has a format error — check the escaped text above for unexpected characters."
        navErrorKind = .urlFormat
        navErrorURLString = raw
        failedInitialURL = nil
        setPageState(.failed(pageFailure(error: URLError(.badURL) as NSError, failedURL: nil,
                                        cause: .badAddress, elapsed: .zero)))
    }

    /// What the error page says under the caption: CFNetwork's description
    /// and the domain/code, kept for diagnosis. Except -1000, which CFNetwork
    /// calls "bad URL" and which is nothing of the kind: it is every SOCKS
    /// failure reply, i.e. the tailnet node could not open the connection.
    /// F4 §4.4 forbids those words for a transport failure, so this states
    /// the one fact the code carries -- which host and port could not be
    /// connected to -- and no more: WHY (refused, unreachable, no answer)
    /// is the relay's reply to tell, and F4 adds it with the evidence.
    nonisolated static func describe(_ error: Error, for url: URL? = nil) -> String {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorBadURL {
            let host = hostLabel(of: url) ?? "the gateway"
            let port = url?.port ?? (url?.scheme?.lowercased() == "http" ? 80 : 443)
            return "The tailnet node couldn't open a connection to \(host) on port \(port). [\(ns.domain) \(ns.code)]"
        }
        var detail = ns.localizedDescription
        if detail.isEmpty { detail = "The page could not be loaded." }
        return "\(detail) [\(ns.domain) \(ns.code)]"
    }

    /// The category the error page shows. -1000 (NSURLErrorBadURL) is NOT a
    /// format error here: it is what WebKit reports for every SOCKS failure
    /// reply (TailnetProxyPolicy.swift's header, measured; GatewayDiscovery
    /// and `isTransientStartupError` say the same), i.e. the proxy could not
    /// open the connection -- so an unreachable gateway used to tell the
    /// owner the address was malformed. The one real format error, a string
    /// URL(string:) rejects, never arrives as an NSError from a navigation;
    /// `reportURLParseFailure` sets `.urlFormat` itself.
    nonisolated static func categorize(_ error: Error) -> NavErrorKind {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain { return .retrieval }
        return .other
    }

    /// The host as the owner knows it (F4 §3): the first DNS label of a
    /// name -- "gateway", not "gateway.example.ts.net" -- and an IP literal
    /// whole. Nil when the URL has no host (about:blank, a parse failure).
    nonisolated static func hostLabel(of url: URL?) -> String? {
        guard let host = url?.host()?.lowercased(), !host.isEmpty else { return nil }
        let isLiteral = host.contains(":") || host.allSatisfy { $0.isNumber || $0 == "." }
        if isLiteral { return host }
        return String(host.split(separator: ".", maxSplits: 1).first ?? Substring(host))
    }

    func clearNavError() {
        // Guard each set: clearNavError runs on the synchronous load path
        // (including from makeWebView during a SwiftUI view update), and
        // @Published fires objectWillChange even when assigning the same value.
        // Skipping no-op assignments avoids publishing during a view update.
        if navError != nil { navError = nil }
        if navErrorMessage != nil { navErrorMessage = nil }
        if navErrorKind != nil { navErrorKind = nil }
        if navErrorURLString != nil { navErrorURLString = nil }
    }

    /// Accepts URL KVO changes only when they cannot change the security origin
    /// shown in browser chrome. WKWebView.url is KVO-compliant and changes for
    /// `history.pushState`, `history.replaceState`, and fragment navigation,
    /// none of which necessarily calls a WKNavigationDelegate commit method.
    ///
    /// WebKit enforces the History API's same-origin rule too, but checking it
    /// again here is deliberate defense in depth: URL KVO also participates in
    /// ordinary/provisional navigation, and a cross-origin request must not be
    /// able to spoof the address bar before it commits.
    private func acceptSameDocumentURL(candidate: URL?) {
        guard let candidate,
              let current = url,
              Self.haveSameWebOrigin(current, candidate)
        else { return }
        url = candidate
    }

    nonisolated static func haveSameWebOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let lhsScheme = lhs.scheme?.lowercased(),
              let rhsScheme = rhs.scheme?.lowercased(),
              ["http", "https"].contains(lhsScheme),
              lhsScheme == rhsScheme,
              let lhsHost = lhs.host()?.lowercased(),
              let rhsHost = rhs.host()?.lowercased(),
              lhsHost == rhsHost
        else { return false }

        func effectivePort(of url: URL, scheme: String) -> Int? {
            url.port ?? (scheme == "http" ? 80 : 443)
        }
        return effectivePort(of: lhs, scheme: lhsScheme)
            == effectivePort(of: rhs, scheme: rhsScheme)
    }

    private func refreshState(from view: WKWebView, includeCommittedURL: Bool = false) {
        title = view.title ?? ""
        if includeCommittedURL {
            // Delegate commit/finish is the authority allowed to change origin.
            url = view.url
        }
        isLoading = view.isLoading
        estimatedProgress = view.estimatedProgress
        canGoBack = view.canGoBack
        canGoForward = view.canGoForward
    }

    private func maybeDumpLoadedPage(_ view: WKWebView) {
        guard TestHooks.flag("-UITestLogResponses") else { return }
        let js = "JSON.stringify({href:location.origin+location.pathname,title:document.title,contentType:document.contentType,body:(document.body?document.body.innerText:'(no body)').substring(0,300)})"
        view.evaluateJavaScript(js) { result, error in
            if let error { logger.log("LOADED-PAGE error: \(error)") }
            else { logger.log("LOADED-PAGE: \(result ?? "(null)")") }
        }
    }
}

extension BrowserViewModel: WKUIDelegate {
#if canImport(UIKit)
    /// Supply a deliberately preview-free menu for links. WebKit's default
    /// context menu includes Safari's large live preview, which can obscure
    /// actions on compact screens.
    func webView(_ webView: WKWebView,
                 contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo,
                 completionHandler: @escaping @MainActor @Sendable (UIContextMenuConfiguration?) -> Void) {
        guard let url = elementInfo.linkURL else {
            completionHandler(nil)
            return
        }
        let configuration = UIContextMenuConfiguration(
            identifier: nil,
            previewProvider: nil
        ) { [weak self] _ in
            let open = UIAction(title: "Open", image: UIImage(systemName: "arrow.up.right.square")) { _ in
                Task { @MainActor [weak self] in self?.openLink(url) }
            }
            // `openExternally` hands the URL to the system browser now that there
            // are no tabs (PLAN §1.4); the label has to say so, or the menu
            // promises something it does not do.
            let openInTab = UIAction(title: "Open in Safari", image: UIImage(systemName: "safari")) { _ in
                Task { @MainActor [weak self] in self?.openExternally(url) }
            }
            let copy = UIAction(title: "Copy Link", image: UIImage(systemName: "doc.on.doc")) { _ in
                Task { @MainActor in UIPasteboard.general.url = url }
            }
            return UIMenu(children: [open, openInTab, copy])
        }
        completionHandler(configuration)
    }
#endif

    /// WebKit asks its UI delegate to create a view for target=_blank,
    /// window.open(), and links whose target requests another browsing
    /// context. Latchkey has exactly one browsing context (PLAN §1.4), so no
    /// view is ever created (nil). The request is decided like a main-frame
    /// navigation (R3): the gateway's own pages load here, in place —
    /// KiroCrew's "pop out chat" opens a same-origin window — and anything
    /// else goes to the system.
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard navigationAction.targetFrame == nil else { return nil }

        // `window.open()` / `window.open('')`: the destination comes later,
        // once the page sets the new window's location. Hand WebKit a
        // throwaway view that catches it, rather than nil — nil makes
        // window.open return null and the page's action silently dies — or
        // loading about:blank here, which would blank the dashboard with no
        // way back.
        guard let url = navigationAction.request.url, !PopupCatcher.isBlank(url) else {
            let catcher = PopupCatcher(
                configuration: configuration,
                route: { [weak self] destination in self?.routeNewWindow(to: destination) },
                finish: { [weak self] done in self?.popupCatchers[ObjectIdentifier(done)] = nil })
            popupCatchers[ObjectIdentifier(catcher)] = catcher
            return catcher.webView
        }
        routeNewWindow(to: url)
        return nil
    }
}

extension BrowserViewModel: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        // A new attempt supersedes any old failure UI, but deliberately does
        // not alter the committed URL rendered in browser chrome.
        clearNavError()
        session?.navigationStarted()
        // A page-initiated navigation has no `loadResolved` stamp. Taken a
        // second early on purpose: the network process can open its
        // connection before this callback reaches the main thread, and an
        // accept dated before the navigation would read as a listener that
        // never answered (R30). An app load's own, exact stamp is kept.
        navigationStartedAt = max(navigationStartedAt, Date().addingTimeInterval(-1))
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        startupRetryTask?.cancel()
        startupRetryTask = nil
        startupLoad = nil
        // The page is on screen: nothing may cover it after this (F4 D8).
        if pageState != .committed {
            logger.log("page-state: committed after \(PageState.milliseconds(elapsedSinceNavigationStart())) ms")
            setPageState(.committed)
        }
        refreshState(from: webView, includeCommittedURL: true)
        failedInitialURL = nil
        session?.navigationCommitted()
        appBar.documentChanged()
        // Back on the dashboard's root: the way-back control has done its job.
        if showsReturnToDashboard, webView.url?.path == "/" || webView.url?.path == "" {
            showsReturnToDashboard = false
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        if TestHooks.flag("-UITestLogResponses") {
            logger.log("RESP-LOG action: \(navigationAction.request.url?.redactedForLog ?? "(nil)") type=\(navigationAction.navigationType.rawValue)")
        }
        // Exactly one destination (R3). A nil targetFrame is a new-window
        // request, which would be a top-level document too.
        let url = navigationAction.request.url
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        switch navigationDecision(for: url, isMainFrame: isMainFrame, in: webView) {
        case .allow:
            decisionHandler(.allow)
        case .openExternally:
            decisionHandler(.cancel)
            if let url {
                logger.log("Navigation leaves the app: \(url.redactedForLog)")
                openExternally(url)
            }
        case .cancel:
            decisionHandler(.cancel)
            logger.log("Navigation refused by policy: \(url?.redactedForLog ?? "(nil)")")
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        let response = navigationResponse.response
        let http = response as? HTTPURLResponse
        if TestHooks.flag("-UITestLogResponses") {
            let url = response.url?.redactedForLog ?? "(nil)"
            if let http {
                logger.log("RESP-LOG response: \(http.statusCode) \(url) mime=\(response.mimeType ?? "?")")
            }
        }
        // F4 §4.13. A main-frame 5xx must not commit: behind `tailscale serve`
        // a stopped Kiro Crew answers 502 on a live port, which produces no
        // NSURLError at all, so without this the empty body becomes the
        // document and the owner gets a blank screen with no explanation.
        let authRequired = (http?.value(forHTTPHeaderField: "X-Auth-Required") ?? "")
            .caseInsensitiveCompare("true") == .orderedSame
        let decision = ResponsePolicy.decide(isMainFrame: navigationResponse.isForMainFrame,
                                             statusCode: http?.statusCode,
                                             authRequired: authRequired)
        guard decision == .commit else {
            // Record the status BEFORE cancelling: WebKit reports a cancelled
            // response as WebKitErrorDomain 102, the same error a cancelled
            // navigation gives, and handlePolicyInterruption would otherwise
            // read this as "the policy refused a redirect" and say the wrong
            // thing (or nothing, if a page is already showing).
            refusedResponseStatus = http?.statusCode
            logger.log("Response refused: HTTP \(http?.statusCode ?? -1) for \(response.url?.redactedForLog ?? "(nil)")")
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        refreshState(from: webView, includeCommittedURL: true)
        maybeDumpLoadedPage(webView)
        session?.navigationFinished()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let ns = error as NSError
        guard !(ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled) else { return }
        if handlePolicyInterruption(ns) { return }
        let failedURL = ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL ?? url ?? initialURL
        if Self.carriesSignInToken(failedURL) { session?.signInLoadFailed() }
        if retryStartupLoadIfAppropriate(error, failedURL: failedURL) { return }
        startupLoad = nil
        navigationError(error, for: failedURL)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let ns = error as NSError
        guard !(ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled) else { return }
        if handlePolicyInterruption(ns) { return }
        // Prefer the failing URL carried by CFNetwork. `webView.url` can be the
        // provisional destination or the old committed page depending on the
        // failure phase, so it is never used as address-bar truth here.
        let failedURL = ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL ?? url ?? initialURL
        if Self.carriesSignInToken(failedURL) { session?.signInLoadFailed() }
        if retryStartupLoadIfAppropriate(error, failedURL: failedURL) { return }
        startupLoad = nil
        navigationError(error, for: failedURL)
    }

    /// WebKit's web content process died (R7, finding H10). Upstream showed a
    /// "cannot load from network" error page and never reloaded, so a routine
    /// memory kill looked exactly like a tailnet outage. Now: reload if the
    /// app is active, within `ContentProcessRecovery`'s budget; defer the
    /// reload to the foreground if it is not; show the error page only when
    /// the budget is spent.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        AppDiagnostics.shared.webContentTerminations += 1
#if canImport(UIKit)
        if UIApplication.shared.applicationState != .active {
            logger.log("Web content process terminated in the background; reloading on return")
            reloadWhenActive = true
            return
        }
#endif
        recoverFromContentProcessTermination(webView)
    }
}

extension BrowserViewModel {
#if LATCHKEY_TEST_HOOKS
    /// Test hook (R7): kills this web view's content process the way iOS
    /// does under memory pressure, so the recovery path can be exercised end
    /// to end. Uses WebKit's private `_killWebContentProcess`, which is why it
    /// is compiled into test builds only (R15).
    func simulateContentProcessTermination() {
        let selector = NSSelectorFromString("_killWebContentProcess")
        guard let webView, webView.responds(to: selector) else {
            logger.log("simulateContentProcessTermination: SPI unavailable")
            return
        }
        logger.log("simulateContentProcessTermination: killing the web content process")
        webView.perform(selector)
    }
#endif

    /// Decides where a new-window request goes (R3). Same-origin web pages
    /// and same-origin blobs load here, in place, with a way back shown; other
    /// origins go to the system; anything the policy cancels is dropped.
    fileprivate func routeNewWindow(to url: URL) {
        guard let webView else { return }
        switch navigationDecision(for: url, isMainFrame: true, in: webView) {
        case .allow:
            guard !PopupCatcher.isBlank(url), url.scheme?.lowercased() != "about" else {
                logger.log("New-window request for \(url.redactedForLog) ignored: nothing to show")
                return
            }
            logger.log("New-window request loads in place: \(url.redactedForLog)")
            showsReturnToDashboard = true
            webView.load(URLRequest(url: url))
        case .openExternally:
            openExternally(url)
        case .cancel:
            logger.log("New-window request refused by navigation policy: \(url.redactedForLog)")
        }
    }

    /// WebKit reports a navigation the policy cancelled mid-flight — a
    /// same-origin link that redirects off the gateway, say — as a failure:
    /// WebKitErrorDomain 102, "frame load interrupted". That is the policy
    /// doing its job, not a network error, and must not paint the error page
    /// over a working dashboard. Returns true when the error was handled.
    fileprivate func handlePolicyInterruption(_ error: NSError) -> Bool {
        guard error.domain == "WebKitErrorDomain", error.code == 102 else { return false }
        startupLoad = nil
        // A response this app refused (F4 §4.13) arrives here as the same 102.
        // It is not a redirect the policy declined, and it must not be treated
        // as one: the gateway is reachable and answered, so say what it said.
        if let status = refusedResponseStatus {
            refusedResponseStatus = nil
            navigationError(error, for: initialURL)
            // navigationError decided the cause from WebKit's 102, which says
            // only "something cancelled it". The status is what the gateway
            // actually answered, so it wins (F4 §4.13). The wording comes from
            // PageFailureText, the single place that owns it.
            let failure = pageFailure(error: error, failedURL: initialURL,
                                      cause: .gatewayError(status: status))
            navErrorMessage = PageFailureText.lines(for: failure).cause
            setPageState(.failed(failure))
            return true
        }
        if webView?.url != nil {
            // A page is showing; leave it. The destination already went to
            // the system (or was refused) in decidePolicyFor.
            logger.log("Navigation interrupted by policy; keeping the current page")
            return true
        }
        // Nothing has ever committed: the app's own first load was redirected
        // somewhere the policy will not show. Say so plainly rather than
        // leaving a blank view.
        let attempted = (error.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? initialURL
        navigationError(error, for: initialURL)
        navErrorMessage = "The gateway redirected to \(attempted.redactedForLog), which is not the gateway this app is set to, so it was not opened here. Check the gateway address in Settings."
        setPageState(.failed(pageFailure(error: error, failedURL: initialURL,
                                         cause: .redirectedAway(attempted.redactedForLog))))
        return true
    }

    /// The way back from a page opened by a new-window request.
    func returnToDashboard() {
        showsReturnToDashboard = false
        if let webView, webView.canGoBack {
            webView.goBack()
        } else {
            load(url: initialURL)
        }
    }

    fileprivate func reloadIfContentProcessDiedInBackground() {
        guard reloadWhenActive, let webView else { return }
        reloadWhenActive = false
        recoverFromContentProcessTermination(webView)
    }

    fileprivate func recoverFromContentProcessTermination(_ webView: WKWebView) {
        guard contentRecovery.shouldReload(now: Date()) else {
            AppDiagnostics.shared.webContentGaveUp += 1
            logger.log("Web content process terminated \(contentRecovery.maxReloads + 1) times in \(Int(contentRecovery.window))s; showing the error page")
            navigationError(URLError(.cannotLoadFromNetwork), for: webView.url ?? url ?? initialURL)
            navErrorMessage = "The dashboard page stopped repeatedly (\(contentRecovery.maxReloads + 1) times in a minute), so automatic reloading has paused. This is the page itself failing, not the tailnet. Reload to try again."
            // The page failed, not the tailnet, and the elapsed time of the last
            // load says nothing about it: this is a committed page dying.
            setPageState(.failed(pageFailure(error: URLError(.cannotLoadFromNetwork) as NSError,
                                             failedURL: webView.url ?? url ?? initialURL,
                                             cause: .pageCrashed(times: contentRecovery.maxReloads + 1,
                                                                 window: Int(contentRecovery.window)),
                                             elapsed: .zero)))
            return
        }
        AppDiagnostics.shared.webContentAutoReloads += 1
        logger.log("Web content process terminated; reloading (\(contentRecovery.recentReloads.count) of \(contentRecovery.maxReloads) in \(Int(contentRecovery.window))s)")
        clearNavError()
        // After a termination WKWebView still knows its URL, and reload()
        // starts a fresh content process for it. Without one (it died before
        // the first commit), start the page over from the app's own URL.
        if webView.url != nil {
            webView.reload()
        } else if let target = url ?? pendingLoadURL {
            loadResolved(target)
        } else {
            didLoadInitial = false
            loadInitial()
        }
    }
}

// MARK: - The dashboard session (M4)

extension BrowserViewModel: SessionHost {
    var sessionOrigin: URL? { allowedOrigin.flatMap { URL(string: $0) } }

    /// Only ever the gateway's own origin: the session layer navigates to
    /// sign-in links, and a sign-in link for anywhere else is refused (R23).
    func loadSessionURL(_ url: URL) {
        guard let allowedOrigin, GatewayAddress.origin(of: url.absoluteString) == allowedOrigin else {
            logger.log("Session: refusing a sign-in navigation outside the gateway origin")
            return
        }
        clearNavError()
        loadResolved(url)
    }

    func sessionFetchStatus(_ path: String, method: String, timeout: Duration?) async -> Int? {
        guard let webView else { return nil }
        do {
            // Whole seconds are all the callers use; 0 means no abort.
            let timeoutMs = timeout.map { Int($0.components.seconds) * 1000 } ?? 0
            let result = try await webView.callAsyncJavaScript(
                PageScriptSources.sessionFetch,
                arguments: ["path": path, "method": method, "timeoutMs": timeoutMs],
                in: nil, contentWorld: SessionManager.world)
            return (result as? NSNumber)?.intValue
        } catch {
            logger.log("Session: \(method) \(path) failed: \(LogRedaction.describe(error))")
            return nil
        }
    }

    func revealSessionBanner() {
        webView?.evaluateJavaScript(PageScriptSources.revealSessionBanner, in: nil,
                                    in: SessionManager.world) { _ in }
    }
}

extension BrowserViewModel {
    nonisolated static func carriesSignInToken(_ url: URL) -> Bool {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.contains { $0.name == "token" } ?? false
    }

    /// `url` without its `token` query parameter (everything else kept).
    nonisolated static func withoutSignInToken(_ url: URL) -> URL {
        guard carriesSignInToken(url),
              var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        c.queryItems = c.queryItems?.filter { $0.name != "token" }
        if c.queryItems?.isEmpty == true { c.queryItems = nil }
        return c.url ?? url
    }
}
