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
       "F4 §4.4: the words 'bad URL' / 'URL format' never appear for a transport failure: \(text)")
expect(text == "The tailnet node couldn't open a connection to gw on port 443. [NSURLErrorDomain -1000]",
       "states the fact the code carries -- host as the owner knows it, port, code -- and guesses no cause (F4 decides that from the relay's reply): \(text)")
expect(BrowserViewModel.describe(socks, for: URL(string: "https://gw.tail-scale.ts.net:8443/x")!).contains("on port 8443"),
       "a non-default port is named")
expect(BrowserViewModel.describe(socks).contains("connection to the gateway on port 443"),
       "with no URL the sentence still reads: \(BrowserViewModel.describe(socks))")
let timedOut = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut,
                       userInfo: [NSLocalizedDescriptionKey: "The request timed out."])
expect(BrowserViewModel.describe(timedOut, for: gw) == "The request timed out. [NSURLErrorDomain -1001]",
       "other codes keep CFNetwork's own text")

print("== the caption (F4 §4.3: today's words until the page is rebuilt), and the host label")
expect(NavErrorKind.retrieval.caption == "Connection error", "a SOCKS failure reads as a connection failure")
expect(NavErrorKind.urlFormat.caption == "URL format error", "a real format error keeps its label")
expect(NavErrorKind.other.caption == nil, "no caption for .other")
expect(BrowserViewModel.hostLabel(of: gw) == "gw", "the first label")
expect(BrowserViewModel.hostLabel(of: URL(string: "https://gw.tail-scale.ts.net:8443/")) == "gw", "the port is not part of the label")
expect(BrowserViewModel.hostLabel(of: URL(string: "https://10.0.0.7/")) == "10.0.0.7", "an IP literal is kept whole")
expect(BrowserViewModel.hostLabel(of: URL(string: "about:blank")) == nil, "no host, no label")

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

print("== pageState (F4 §4.3): the failure it publishes beside the old fields")
// A parse failure is the one real format error, and it had no load in flight,
// so it must not borrow the previous load's clock.
if case .failed(let f) = vm.pageState {
    expect(f.cause == .badAddress, "a parse failure is .badAddress: \(f.cause.logName)")
    expect(f.elapsed == .zero, "and carries no elapsed time, having never dialled: \(f.elapsed)")
} else {
    expect(false, "a parse failure publishes a failed page state, got \(vm.pageState.logName)")
}

// The relay's reply is only believed when it is about THIS load. Each of the
// three conditions is checked on its own, because getting any of them wrong
// gives the owner a confident and wrong explanation -- the failure mode this
// whole mechanism exists to avoid.
func stateAfterSocksFailure(_ reply: ProxyReply?, on vm: BrowserViewModel,
                            model: TSNetModel) -> PageState.Failure? {
    model.lastProxyFailure = reply
    vm.navigationError(socks, for: gw)
    if case .failed(let f) = vm.pageState { return f }
    return nil
}

let m2 = TSNetModel()
let vm2 = BrowserViewModel(model: m2, initialURL: gw, dataStore: .nonPersistent())
let hostPort = "\(gw.host!):443"
let matching = ProxyReply(target: hostPort, reply: "connection refused",
                          elapsed: .milliseconds(12), at: Date().addingTimeInterval(1))
let f1 = stateAfterSocksFailure(matching, on: vm2, model: m2)
expect(f1?.proxyReply != nil, "a reply for this host, port and load is attached")
expect(f1?.cause == .refused, "and decides the cause: \(f1?.cause.logName ?? "nil")")

let otherHost = ProxyReply(target: "other.tail-scale.ts.net:443", reply: "connection refused",
                           elapsed: .milliseconds(12), at: Date().addingTimeInterval(1))
let f2 = stateAfterSocksFailure(otherHost, on: vm2, model: m2)
expect(f2?.proxyReply == nil, "a reply for ANOTHER host is not attached -- a discovery sweep refuses twelve of them a second before the page's own attempt")
expect(f2?.cause != .refused, "so it cannot decide this page's cause")

let otherPort = ProxyReply(target: "\(gw.host!):8443", reply: "connection refused",
                           elapsed: .milliseconds(12), at: Date().addingTimeInterval(1))
expect(stateAfterSocksFailure(otherPort, on: vm2, model: m2)?.proxyReply == nil,
       "nor a reply for another port on the same host (F1: the port is part of the gateway)")

let stale = ProxyReply(target: hostPort, reply: "connection refused",
                       elapsed: .milliseconds(12), at: Date().addingTimeInterval(-3600))
expect(stateAfterSocksFailure(stale, on: vm2, model: m2)?.proxyReply == nil,
       "nor one from before this load began -- the previous load's refusal must not explain this one")

let upper = ProxyReply(target: hostPort.uppercased(), reply: "host unreachable",
                       elapsed: .milliseconds(12), at: Date().addingTimeInterval(1))
expect(stateAfterSocksFailure(upper, on: vm2, model: m2)?.cause == .unreachable,
       "the target compares case-insensitively: WebKit sends what it was given, the qualifier lowercases")

expect(BrowserViewModel.firstLabel(of: "byskebox.example.ts.net") == "byskebox",
       "the owner sees the first label")
expect(BrowserViewModel.firstLabel(of: "byskebox") == "byskebox", "a bare label is itself")
expect(BrowserViewModel.firstLabel(of: "") == "", "and an empty host does not crash")

print(failures == 0 ? "\(checks)/\(checks) browser view model checks passed" : "\(failures) of \(checks) browser view model checks FAILED")
exit(failures == 0 ? 0 : 1)
