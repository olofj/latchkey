// Copyright (c) 2026 Olof Johansson
// SPDX-License-Identifier: BSD-3-Clause

// Stand-ins for what App/Browser/BrowserViewModel.swift reads from TSNet and
// TailscaleKit, so the REAL view model compiles on the host for
// scripts/test-browser-view-model.sh: only the fields it touches, shaped as
// TSNetModel.swift declares them. IpnState comes from
// test-proxy-policy-stubs.swift and `logger` from test-socks-relay-stubs.swift.

import Combine
import Foundation
import Network

enum Ipn {
    enum State: Equatable, Sendable {
        case NoState, InUseOtherUser, NeedsLogin, NeedsMachineAuth, Stopped, Starting, Running
    }
}

@MainActor
final class TSNetModel: ObservableObject {
    @Published var state: Ipn.State? = nil
    @Published var proxyConfiguration: ProxyConfiguration?
    @Published var localStatus: IpnState.Status?
    @Published var proxyPolicy: TailnetProxyPolicy?
    var proxyEndpointGeneration: UInt64 = 0
    /// The relay's last refused CONNECT (F4 §4.5). Here so the host test can
    /// plant one and check that the page only believes a reply that is for its
    /// own host, port and load.
    @Published var lastProxyFailure: ProxyReply?
}

@MainActor
final class AppDiagnostics: ObservableObject {
    static let shared = AppDiagnostics()
    @Published var webContentTerminations = 0
    @Published var webContentAutoReloads = 0
    @Published var webContentGaveUp = 0
    @Published var contentRulesFailures = 0
    @Published var offOriginLoadsBlocked = 0
    @Published var gatewayAssetFailures = 0
    @Published var offOriginHostsContacted: [String: Int] = [:]
    private init() {}
}
