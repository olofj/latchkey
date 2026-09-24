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

print(failures == 0 ? "\(checks)/\(checks) browser view model checks passed" : "\(failures) of \(checks) browser view model checks FAILED")
exit(failures == 0 ? 0 : 1)
