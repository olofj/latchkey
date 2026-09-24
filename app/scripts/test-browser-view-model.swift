// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

// Host tests for App/Browser/BrowserViewModel.swift's pure parts. Run by
// scripts/test-browser-view-model.sh.

import Foundation
import WebKit

var failures = 0
var checks = 0
func expect(_ cond: Bool, _ what: String) {
    checks += 1
    if !cond { failures += 1; print("  FAIL \(what)") }
}

print("== the web view configuration (D1)")
// WebKit's fraudulent-website check submits every main-frame navigation to
// the system's fraud-check service: a destination outside the split tunnel,
// from a process check-no-log-upload.sh does not watch. The default is on,
// which is why this test exists; a default that were off would make the
// assertion vacuous, so that is checked too.
expect(WKWebViewConfiguration().preferences.isFraudulentWebsiteWarningEnabled,
       "WebKit's default is to check (otherwise the next check proves nothing)")
let store = WKWebsiteDataStore.nonPersistent()
let configuration = BrowserViewModel.makeWebViewConfiguration(dataStore: store)
expect(!configuration.preferences.isFraudulentWebsiteWarningEnabled,
       "the dashboard's configuration turns the fraud check off: no per-navigation egress but the gateway (D1)")
expect(configuration.websiteDataStore === store, "the workspace's data store is the one used")
expect(!configuration.upgradeKnownHostsToHTTPS, "no HTTPS upgrade rewriting (the gateway is https already; kept as before)")

print("== a SOCKS failure is not a URL format error (F4)")
// WebKit reports EVERY SOCKS failure reply as NSURLErrorBadURL (-1000):
// measured in TailnetProxyPolicy.swift's header, stated again in
// GatewayDiscovery.swift and isTransientStartupError. An unreachable gateway
// used to tell the owner the address was malformed.
let socks = NSError(domain: NSURLErrorDomain, code: NSURLErrorBadURL,
                    userInfo: [NSLocalizedDescriptionKey: "bad URL"])
expect(BrowserViewModel.categorize(socks) == .retrieval,
       "-1000 is a transport failure, not .urlFormat: \(BrowserViewModel.categorize(socks))")
for code in [NSURLErrorTimedOut, NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost,
             NSURLErrorNetworkConnectionLost, NSURLErrorSecureConnectionFailed] {
    expect(BrowserViewModel.categorize(NSError(domain: NSURLErrorDomain, code: code)) == .retrieval,
           "NSURLErrorDomain \(code) is retrieval")
}
expect(BrowserViewModel.categorize(NSError(domain: "WebKitErrorDomain", code: 102)) == .other,
       "a WebKit policy interruption has no category")

let gw = URL(string: "https://gw.tail-scale.ts.net/")!
let text = BrowserViewModel.describe(socks, for: gw)
expect(!text.lowercased().contains("bad url") && !text.contains("URL format"),
       "F4: the words 'bad URL' / 'URL format' never appear for a transport failure: \(text)")
expect(text.contains("connection to gw on port 443") && !text.contains("gw.tail-scale"),
       "names the host as the owner knows it (first label) and the port: \(text)")
expect(text.contains("isn't allowed to reach gw yet, or gw is off") && text.contains("Settings → Status"),
       "F4 §4.4's likely cause and what to do next: \(text)")
expect(text.hasSuffix("[NSURLErrorDomain -1000]"), "the code stays, for diagnosis")
expect(BrowserViewModel.describe(socks, for: URL(string: "https://gw.tail-scale.ts.net:8443/x")!).contains("on port 8443"),
       "a non-default port is named")
expect(BrowserViewModel.describe(socks).contains("connection to the gateway on port 443"),
       "with no URL the sentence still reads: \(BrowserViewModel.describe(socks))")
let timedOut = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut,
                       userInfo: [NSLocalizedDescriptionKey: "The request timed out."])
expect(BrowserViewModel.describe(timedOut, for: gw) == "The request timed out. [NSURLErrorDomain -1001]",
       "other codes keep CFNetwork's own text")

print("== the caption, and the host as shown")
expect(NavErrorKind.retrieval.caption(host: "gw") == "Couldn't reach gw", "F4's title for a retrieval failure")
expect(NavErrorKind.retrieval.caption(host: nil) == "Couldn't reach the gateway", "and without a host")
expect(NavErrorKind.urlFormat.caption(host: "gw") == "Latchkey can't open this address",
       "F4's title for a malformed address")
expect(NavErrorKind.other.caption(host: "gw") == nil, "no caption for .other")
expect(BrowserViewModel.displayHost(of: gw) == "gw", "the first label")
expect(BrowserViewModel.displayHost(of: URL(string: "https://gw.tail-scale.ts.net:8443/")) == "gw:8443",
       "with the port when it is not the scheme's default")
expect(BrowserViewModel.displayHost(of: URL(string: "http://gw:80/")) == "gw", "the default port is not shown")
expect(BrowserViewModel.displayHost(of: URL(string: "https://10.0.0.7/")) == "10.0.0.7", "an IP literal is kept whole")
expect(BrowserViewModel.displayHost(of: URL(string: "about:blank")) == nil, "no host, no caption host")

print("== through the view model itself")
// The real paths that set the page's kind and message; the failure report
// callback is nil, as in the harnesses.
let model = TSNetModel()
let vm = BrowserViewModel(model: model, initialURL: gw, dataStore: .nonPersistent())
vm.navigationError(socks, for: gw)
expect(vm.navErrorKind == .retrieval, "a -1000 navigation error is categorised as retrieval on the page: \(String(describing: vm.navErrorKind))")
expect(vm.navErrorMessage?.lowercased().contains("bad url") == false && vm.navErrorMessage?.contains("gw") == true,
       "and its message says what happened: \(vm.navErrorMessage ?? "nil")")
expect(vm.navErrorURLString == gw.absoluteString && vm.failedInitialURL == gw, "the URL and the initial-load flag as before")
vm.clearNavError()
vm.reportURLParseFailure("https://gw\u{200B}.tail-scale.ts.net/")
expect(vm.navErrorKind == .urlFormat, ".urlFormat is still reachable, only for input URL(string:) rejects")
expect(vm.navErrorMessage?.contains("format error") == true, "with the parse failure's own text")

print(failures == 0 ? "\(checks)/\(checks) browser view model checks passed" : "\(failures) of \(checks) browser view model checks FAILED")
exit(failures == 0 ? 0 : 1)
